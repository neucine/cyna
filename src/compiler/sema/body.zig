const type_resolution = @import("type_resolution.zig");
const declarations = @import("declarations.zig");
const protocols = @import("protocols.zig");
const package_manifest = @import("../package.zig");
const lexer = @import("../lexer/lexer.zig");
const generics = @import("generics.zig");
const generic_shapes = generics.shapes;
const generated_names = @import("../generated_names.zig");
const concurrency = @import("concurrency.zig");
const std = @import("std");
const ast = @import("../parser/ast.zig");
const diagnostics = @import("../diagnostics.zig");
const generic_definition_body_check = generic_origins.definition_body;
const generic_origins = @import("generic_origins.zig");
const identity = @import("identity.zig");
const intrinsics = @import("../intrinsics.zig");
const language_contracts = @import("../language_contracts.zig");
const method_use_settlement = generic_origins.method_use;
const ownership_owner = @import("ownership.zig");
const semantic_types = @import("types.zig");
const sir = @import("sir.zig");
const sir_method_use_ids = generic_origins.method_use;

/// Field access resolution shared by the body owner and the entry relays that
/// expose it to other semantic modules.
pub const StructFieldAccess = struct {
    struct_decl_id: identity.DeclId,
    struct_name: []const u8,
    decl: declarations.StructLookup,
    decl_field: declarations.StructFieldLookup,
    field_type_id: semantic_types.TypeId,
};

pub const UnionPayloadAccess = struct {
    union_decl_id: identity.DeclId,
    union_name: []const u8,
    field_type_id: semantic_types.TypeId,
};

/// Function body entry points and definition-site generic body trials.
pub fn Owner(comptime host: anytype) type {
    return struct {
        const SemaContext = host.SemaContext;
        const SemaError = host.SemaError;
        const lookup = declarations.Lookup(SemaContext);
        const GlobalBinding = host.GlobalBinding;
        const LocalBinding = host.LocalBinding;
        const canonical = type_resolution.Canonical(SemaContext);
        const canonicalPrimitiveTypeId = canonical.primitiveType;
        const canonicalResultTypeId = canonical.resultType;
        const canonicalTypeNode = canonical.typeNode;
        const canonicalArrayTypeId = canonical.arrayType;
        const canonicalDenseArrayTypeId = canonical.denseArrayType;
        const canonicalFloatLiteralTypeName = canonical.floatLiteralType;
        const canonicalFloatTypeId = canonical.floatType;
        const canonicalInferredIntegerTypeId = canonical.inferredIntegerType;
        const canonicalIntegerLiteralTypeName = canonical.integerLiteralType;
        const canonicalIntegerTypeId = canonical.integerType;
        const canonicalNominalDeclId = canonical.nominalDecl;
        const canonicalNominalTypeId = canonical.nominalType;
        const canonicalOptionalTypeId = canonical.optionalType;
        const canonicalOwnedTarget = canonical.ownedTargetType;
        const canonicalOwnedTypeId = canonical.ownedType;
        const canonicalRawTypeId = canonical.rawType;
        const canonicalQualifiedRawTypeId = canonical.qualifiedRawType;
        const canonicalRefIsConst = canonical.refIsConstant;
        const canonicalRefTarget = canonical.refTargetType;
        const canonicalSliceIsConst = canonical.sliceIsConstant;
        const canonicalSliceTypeId = canonical.sliceType;
        const canonicalSparseArrayTypeId = canonical.sparseArrayType;
        const canonicalTypeInterner = canonical.interner;
        const canonicalTypeIsVoidLike = canonical.voidLike;
        const canonicalTypeKind = canonical.sirType;
        const canonicalTypeIsOwnedValue = host.typeIsOwnedValue;
        const canonicalUnwrapOwned = canonical.unwrapOwnedType;
        const canonicalConstRefTypeId = canonical.constRefType;
        const canonicalRefTypeId = canonical.refType;
        const finalizeAndRecordExprSemantics = host.finalizeAndRecordExprSemantics;
        fn findLocal(locals: []const LocalBinding, needle: []const u8) ?LocalBinding {
            var index = locals.len;
            while (index > 0) {
                index -= 1;
                if (std.mem.eql(u8, locals[index].name, needle)) return locals[index];
            }
            return null;
        }
        fn findLocalIndex(locals: []const LocalBinding, needle: []const u8) ?usize {
            var index = locals.len;
            while (index > 0) {
                index -= 1;
                if (std.mem.eql(u8, locals[index].name, needle)) return index;
            }
            return null;
        }
        fn optionalLocalPayload(context: *SemaContext, locals: []const LocalBinding, name: ast.Name) ?semantic_types.TypeId {
            const local = findLocal(locals, name.text) orelse return null;
            if (local.is_unavailable) return null;
            return switch (canonicalTypeNode(context, local.type_id).*) {
                .optional => |payload| payload,
                else => null,
            };
        }

        fn optionalEarlyReturnGuard(context: *SemaContext, locals: []const LocalBinding, stmt: ast.Stmt) ?ast.Name {
            if (stmt != .@"if") return null;
            const branch = stmt.@"if";
            if (branch.else_body.len != 0 or branch.then_body.len != 1 or branch.then_body[0] != .@"return") return null;
            const subject = switch (branch.condition.*) {
                .is_test => |is_test| if (is_test.kind == .optional_none and is_test.capture_name == null) is_test.subject else return null,
                else => return null,
            };
            if (subject.* != .name) return null;
            const name = subject.name;
            if (optionalLocalPayload(context, locals, name) == null) return null;
            return name;
        }
        const findStruct = lookup.findStruct;
        const instantiateGenericStructWithTypeArgs = host.instantiateGenericStructWithTypeArgs;
        const makeTypedExprFromId = host.makeTypedExprFromId;
        const maybeRecordSemanticHoverFact = host.maybeRecordSemanticHoverFact;
        const maybeRegisteredDeclId = lookup.maybeRegisteredDeclId;
        const nextBindingId = lookup.nextBindingId;
        const parseCanonicalType = host.parseCanonicalType;
        const borrowedPlaceDependencyForStoredValue = host.borrowedPlaceDependencyForStoredValue;
        const loweredCAbiSymbolName = host.loweredCAbiSymbolName;
        const recordExprSink = host.recordExprSink;
        const rootedBorrowProvenanceForType = host.rootedBorrowProvenanceForType;
        const BuiltinClearKind = host.BuiltinClearKind;
        const BuiltinContainsKind = host.BuiltinContainsKind;
        const BuiltinLenKind = host.BuiltinLenKind;
        const BuiltinSequenceLiteralKind = host.BuiltinSequenceLiteralKind;
        const CheckedMethodAuthority = host.CheckedMethodAuthority;
        const GenericReceiverOrigin = host.GenericReceiverOrigin;
        const InstantiatedStructField = host.InstantiatedStructField;
        const IteratorHookSource = host.IteratorHookSource;
        const LoopBlockChannelsResult = host.LoopBlockChannelsResult;
        const LoopStmtChannels = host.LoopStmtChannels;
        const LoweredAnonymousFunction = host.LoweredAnonymousFunction;
        const LoweredHomogeneousLiteralItems = host.LoweredHomogeneousLiteralItems;
        const LoweredTakePlace = host.LoweredTakePlace;
        const Provenance = host.Provenance;
        const ResultCasePayload = host.ResultCasePayload;
        const TakeAstStep = host.TakeAstStep;
        const TypeBuiltinInsertMethod = host.TypeBuiltinInsertMethod;
        const TypeBuiltinReserveMethod = host.TypeBuiltinReserveMethod;
        const TypeBuiltinPopMethod = host.TypeBuiltinPopMethod;
        const TypeExpectationOrigin = host.TypeExpectationOrigin;
        const TypedExpr = host.TypedExpr;
        const accumulateBorrowRootMutationProvenance = host.accumulateBorrowRootMutationProvenance;
        const attachCheckedCallUse = host.attachCheckedCallUse;
        const buildCheckedPlaceProjections = host.buildCheckedPlaceProjections;
        const canAccessDecl = lookup.canAccessDecl;
        const canonicalStructLookup = lookup.canonicalStructLookup;
        const canonicalUnionLookup = lookup.canonicalUnionLookup;
        const lookupStructDeclById = lookup.lookupStructDeclById;
        const lookupUnionDeclById = lookup.lookupUnionDeclById;
        const findInstantiatedStructForCanonicalType = lookup.findInstantiatedStructForCanonicalType;
        const checkedStoredBorrowDependency = host.checkedStoredBorrowDependency;
        const constIndexValue = host.constIndexValue;
        const emitOwnershipDiagnostic = host.emitOwnershipDiagnostic;
        const emitScopedAllocEscape = host.emitScopedAllocEscape;
        const emitUnavailableLocal = host.emitUnavailableLocal;
        const expectAsmInputType = host.expectAsmInputType;
        const expectAsmResultType = host.expectAsmResultType;
        const expectMutablePlaceRoot = host.expectMutablePlaceRoot;
        const expectMutableReceiver = host.expectMutableReceiver;
        const expectType = canonical.expectType;
        const expectTypeFrom = canonical.expectTypeWithOrigin;
        const exprCarriesScopedAlloc = host.exprCarriesScopedAlloc;
        const exprCarriesScopedAllocAs = host.exprCarriesScopedAllocAs;
        const findAccessibleStruct = lookup.findAccessibleStruct;
        const findAstFunction = host.findAstFunction;
        const findEnum = lookup.findEnum;
        const global_lookup = declarations.GlobalLookup(SemaContext, GlobalBinding);
        const findGlobal = global_lookup.findGlobal;
        const findGlobalInModule = global_lookup.findGlobalInModule;
        const findGlobalMemberInModule = global_lookup.findGlobalMemberInModule;
        const findImportedModulePath = lookup.findImportedModulePath;
        const findInstantiatedStruct = lookup.findInstantiatedStruct;
        const findLiteralField = host.findLiteralField;
        const findStructInModule = lookup.findStructInModule;
        const firstExprToken = ast.firstExprToken;
        const formatCanonicalTypeDisplay = canonical.formatType;
        const formatTypeDisplay = canonical.formatType;
        const instantiateMethodCall = host.instantiateMethodCall;
        const isDefinitionSiteBinder = host.isDefinitionSiteBinder;
        const localMutationTargetScopeDepth = host.localMutationTargetScopeDepth;
        const lookupEnumDeclById = lookup.lookupEnumDeclById;
        const lookupStructField = lookup.lookupStructField;
        const lowerAsmClobber = host.lowerAsmClobber;
        const lowerAsmConstraint = host.lowerAsmConstraint;
        const lowerComptimeExpr = host.lowerComptimeExpr;
        const lowerImplicitHandoff = host.lowerImplicitHandoff;
        const markCheckedNamedHandoff = host.markCheckedNamedHandoff;
        const markLocalHandedOff = host.markLocalHandedOff;
        const namedFloatBitWidth = canonical.floatBitWidth;
        const namedIntBitWidth = canonical.intBitWidth;
        const normalizedStructReceiverType = host.normalizedStructReceiverType;
        const optionalEql = host.optionalEql;
        const parseType = host.parseType;
        const parseTypeWithBindings = host.parseTypeWithBindings;
        const placeholder_generic_scope = host.placeholder_generic_scope;
        const projectedReadValueSemantics = host.projectedReadValueSemantics;
        const provenanceOutlivesScope = host.provenanceOutlivesScope;
        const provenanceRootToken = host.provenanceRootToken;
        const recordExprMetadata = host.recordExprMetadata;
        const recordGeneratedBindingRoot = host.recordGeneratedBindingRoot;
        const recordMutationProvenance = host.recordMutationProvenance;
        const registerGeneratedDecl = lookup.registerGeneratedDecl;
        const registeredDeclId = lookup.registeredDeclId;
        const rejectArrowCallableStorageType = host.rejectArrowCallableStorageType;
        const rejectBorrowedProvenanceAssignmentEscape = host.rejectBorrowedProvenanceAssignmentEscape;
        const rejectBorrowedProvenanceMutationEscape = host.rejectBorrowedProvenanceMutationEscape;
        const rejectBorrowedProvenanceReturnEscape = host.rejectBorrowedProvenanceReturnEscape;
        const rejectIsolatedCallToFunction = host.rejectIsolatedCallToFunction;
        const rejectIsolatedMutableGlobalAccess = host.rejectIsolatedMutableGlobalAccess;
        const rejectLiveBorrowContainerMutationConflict = host.rejectLiveBorrowContainerMutationConflict;
        const rejectLiveBorrowInvalidation = host.rejectLiveBorrowInvalidation;
        const rejectLiveBorrowPlaceMutationConflict = host.rejectLiveBorrowPlaceMutationConflict;
        const rejectProjectedBindingWritableAliasConflict = host.rejectProjectedBindingWritableAliasConflict;
        const rejectProjectedBindingMutableAliasCreation = host.rejectProjectedBindingMutableAliasCreation;
        const rejectProjectedBindingWritableCall = host.rejectProjectedBindingWritableCall;
        const rejectProjectedResourceTransferForTypedValue = host.rejectProjectedResourceTransferForTypedValue;
        const rejectScopedAllocCallEscape = host.rejectScopedAllocCallEscape;
        const rejectScopedAllocMutationEscape = host.rejectScopedAllocMutationEscape;
        const resolvePlace = host.resolvePlace;
        const selectSyntaxMethod = host.selectSyntaxMethod;
        const semanticExprMetadata = host.semanticExprMetadata;
        const canonicalNominalDeclName = lookup.canonicalNominalDeclName;
        const syntaxMethodReturnType = host.syntaxMethodReturnType;
        const typeConstructionContext = canonical.interContext;
        const typeIsOwnedForProtocol = host.typeIsOwnedForProtocol;
        const typeIsOwnedValue = host.typeIsOwnedValue;
        const typeIsThreadTransferable = host.typeIsThreadTransferable;
        const typeIteratorHookRole = host.typeIteratorHookRole;
        const typeIteratorInitRole = host.typeIteratorInitRole;
        const typeIteratorReadRole = host.typeIteratorReadRole;
        const typeMayCaptureAllocator = host.typeMayCaptureAllocator;
        const typeMayCarryBorrowedProvenance = host.typeMayCarryBorrowedProvenance;
        const validateAsmExprPlaceholders = host.validateAsmExprPlaceholders;
        const validateAsmPlaceholders = host.validateAsmPlaceholders;
        const validateBoundaryArguments = host.validateBoundaryArguments;
        const validateBoundaryCall = host.validateBoundaryCall;
        const ShapeProjection = host.ShapeProjection;
        const declaration_index = host.declaration_index;
        const InstantiatedStructDecl = host.InstantiatedStructDecl;
        const StructLookup = declarations.StructLookup;
        const packedFieldViolation = host.packedFieldViolation;
        const isPackedFieldType = host.isPackedFieldType;
        const isPackedStructType = host.isPackedStructType;
        const sharedRuntimeForContract = host.sharedRuntimeForContract;
        const dropRuntimeForContract = host.dropRuntimeForContract;
        const MethodUseKey = host.MethodUseKey;
        const GenericContractFunction = host.GenericContractFunction;
        const ConcreteCall = host.ConcreteCall;
        const synthesizeHostedThreadTrampoline = host.synthesizeHostedThreadTrampoline;
        const synthesizeTaskGroupTrampoline = host.synthesizeTaskGroupTrampoline;
        const canonicalBaseStructDecl = host.canonicalBaseStructDecl;
        const summarizeBorrowEscapeRelation = host.summarizeBorrowEscapeRelation;
        const placeRootProvenance = host.placeRootProvenance;
        const isAutoloadModule = lookup.isAutoloadModule;
        const rawPointeeTypeName = host.rawPointeeTypeName;
        const parseTypeDepth = host.parseTypeDepth;
        const ResolvedAstFunction = host.ResolvedAstFunction;
        const name_resolution = declarations.resolution;
        const queryViewSourceBorrowRoots = host.queryViewSourceBorrowRoots;
        const isBorrowProducingViewExpr = host.isBorrowProducingViewExpr;
        const UnknownValueKind = host.UnknownValueKind;
        const formatFunctionTypeSignature = canonical.functionTypeSignature;
        const isCAbiScalarTypeName = host.isCAbiScalarTypeName;
        const StructFieldLookup = declarations.StructFieldLookup;
        const canonicalInstantiatedStructTypeId = lookup.canonicalInstantiatedStructTypeId;
        const declarationSpan = host.declarationSpan;
        const findModuleInfo = lookup.moduleInfo;
        const findStructAny = lookup.findStructAny;
        const internCallableType = host.internCallableType;
        const provenanceCanEscapeFunction = host.provenanceCanEscapeFunction;
        const resolveTypeAliasInTypeScope = type_resolution.resolveTypeAliasInTypeScope;
        const emitCallBorrowEscape = host.emitCallBorrowEscape;
        const resolveStructInTypeScope = type_resolution.resolveStructInTypeScope;
        const callEscapeTarget = host.callEscapeTarget;
        const provenanceOutlivesTarget = host.provenanceOutlivesTarget;

        pub fn snapshotLocalState(allocator: std.mem.Allocator, locals: []const LocalBinding) ![]LocalBinding {
            return try allocator.dupe(LocalBinding, locals);
        }

        pub fn restoreLocalState(locals: []LocalBinding, snapshot: []const LocalBinding) void {
            std.debug.assert(locals.len == snapshot.len);
            @memcpy(locals, snapshot);
        }

        pub fn mergeBorrowedPlaceDependency(a: ownership_owner.BorrowedPlaceDependency, b: ownership_owner.BorrowedPlaceDependency) ownership_owner.BorrowedPlaceDependency {
            return ownership_owner.mergeBorrowedDependency(a, b, ownership_owner.conservativeBorrowProjection);
        }

        pub fn mergeOptionalExprOrigin(a: ?*ast.Expr, b: ?*ast.Expr) ?*ast.Expr {
            return if (a == b) a else null;
        }

        pub fn mergeUnavailableOrigin(a: LocalBinding, b: LocalBinding) ?lexer.Token {
            if (!a.is_unavailable) return b.unavailable_at;
            if (!b.is_unavailable) return a.unavailable_at;
            return a.unavailable_at orelse b.unavailable_at;
        }

        pub fn mergeJoinedLocalState(context: *SemaContext, out: []LocalBinding, a: []const LocalBinding, b: []const LocalBinding) SemaError!void {
            std.debug.assert(out.len == a.len);
            std.debug.assert(a.len == b.len);

            var i: usize = 0;
            while (i < out.len) : (i += 1) {
                out[i].provenance = Provenance.combine(a[i].provenance, b[i].provenance);
                out[i].borrowed_place = mergeBorrowedPlaceDependency(a[i].borrowed_place, b[i].borrowed_place);
                out[i].projection_origin = if (out[i].borrowed_place.hasBorrow())
                    mergeOptionalExprOrigin(a[i].projection_origin, b[i].projection_origin)
                else
                    null;
                out[i].unavailable_at = mergeUnavailableOrigin(a[i], b[i]);
                out[i].is_unavailable = a[i].is_unavailable or b[i].is_unavailable;
                out[i].deferred_handoff_depth = a[i].deferred_handoff_depth orelse b[i].deferred_handoff_depth;
                out[i].deferred_handoff_at = a[i].deferred_handoff_at orelse b[i].deferred_handoff_at;
                out[i].is_scoped_alloc_value = a[i].is_scoped_alloc_value or b[i].is_scoped_alloc_value;
                out[i].scoped_alloc_origin = if (out[i].is_scoped_alloc_value)
                    mergeOptionalExprOrigin(a[i].scoped_alloc_origin, b[i].scoped_alloc_origin)
                else
                    null;
                // A binding reachable from two branches can stand for either branch's
                // binder, so the merged shape joins both.
                out[i].generic_shape = try genericShapeJoinReturns(context, a[i].generic_shape, b[i].generic_shape);
            }
        }

        pub fn mergeJoinedLocalStateInPlace(context: *SemaContext, acc: []LocalBinding, branch: []const LocalBinding) SemaError!void {
            std.debug.assert(acc.len == branch.len);

            var i: usize = 0;
            while (i < acc.len) : (i += 1) {
                acc[i].provenance = Provenance.combine(acc[i].provenance, branch[i].provenance);
                acc[i].borrowed_place = mergeBorrowedPlaceDependency(acc[i].borrowed_place, branch[i].borrowed_place);
                acc[i].projection_origin = if (acc[i].borrowed_place.hasBorrow())
                    mergeOptionalExprOrigin(acc[i].projection_origin, branch[i].projection_origin)
                else
                    null;
                acc[i].unavailable_at = mergeUnavailableOrigin(acc[i], branch[i]);
                acc[i].is_unavailable = acc[i].is_unavailable or branch[i].is_unavailable;
                acc[i].deferred_handoff_depth = acc[i].deferred_handoff_depth orelse branch[i].deferred_handoff_depth;
                acc[i].deferred_handoff_at = acc[i].deferred_handoff_at orelse branch[i].deferred_handoff_at;
                acc[i].is_scoped_alloc_value = acc[i].is_scoped_alloc_value or branch[i].is_scoped_alloc_value;
                acc[i].scoped_alloc_origin = if (acc[i].is_scoped_alloc_value)
                    mergeOptionalExprOrigin(acc[i].scoped_alloc_origin, branch[i].scoped_alloc_origin)
                else
                    null;
                acc[i].generic_shape = try genericShapeJoinReturns(context, acc[i].generic_shape, branch[i].generic_shape);
            }
        }

        pub fn localAbstractStateEql(a: []const LocalBinding, b: []const LocalBinding) bool {
            return ownership_owner.localAbstractStateEqual(a, b);
        }

        pub fn mergeOptionalLocalState(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            acc: *?[]LocalBinding,
            state: []const LocalBinding,
        ) SemaError!void {
            if (acc.*) |existing| {
                try mergeJoinedLocalStateInPlace(context, existing, state);
                return;
            }
            acc.* = try snapshotLocalState(allocator, state);
        }

        pub fn switchPayloadCaptureProvenance(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            subject_expr: ?*ast.Expr,
            payload_type: semantic_types.TypeId,
            subject_provenance: Provenance,
        ) SemaError!Provenance {
            if (!try typeMayCarryBorrowedProvenance(context, path, program, current_module, payload_type)) return .none();
            const subject_view_provenance = if (subject_expr) |expr|
                try sourceViewProvenance(context, path, program, current_module, globals, locals, expr)
            else
                Provenance.none();

            const subject_value_can_escape = ownership_owner.provenanceCanEscapeFunction(locals, subject_provenance);
            const subject_view_can_escape = ownership_owner.provenanceCanEscapeFunction(locals, subject_view_provenance);
            if (subject_view_can_escape) {
                if (subject_value_can_escape) {
                    return Provenance.combine(subject_provenance, subject_view_provenance);
                }
                return subject_view_provenance;
            }
            return subject_provenance;
        }

        /// A binder stands for an unknown concrete type, so the switch cannot resolve
        /// its case set at the definition site. The trial body models the switch as the
        /// straight sequence of its case bodies: every body is still lowered, recorded,
        /// and admitted against the binders' declared protocols, and each specialization
        /// re-lowers the switch with the substituted concrete type.
        pub fn sirBlockDefinitelyTerminates(body: []const sir.Stmt) bool {
            if (body.len == 0) return false;
            return sirStmtDefinitelyTerminates(body[body.len - 1]);
        }

        pub fn sirStmtDefinitelyTerminates(stmt: sir.Stmt) bool {
            return switch (stmt) {
                .@"return" => true,
                .expr => |expr| sir.exprDefinitelyDiverges(expr),
                .@"if" => |if_stmt| sirBlockDefinitelyTerminates(if_stmt.then_body) and sirBlockDefinitelyTerminates(if_stmt.else_body),
                .unchecked => |body| sirBlockDefinitelyTerminates(body),
                .using_alloc => |using_alloc| sirBlockDefinitelyTerminates(using_alloc.body),
                else => false,
            };
        }

        pub fn placeDerefOperand(expr: *ast.Expr) ?*ast.Expr {
            var cursor = expr;
            while (true) {
                switch (cursor.*) {
                    .field => |field| cursor = field.object,
                    .index => |index| cursor = index.object,
                    .deref => |deref| return deref.expr,
                    else => return null,
                }
            }
        }

        pub fn borrowedRootTypeForPath(context: *SemaContext, local: LocalBinding, source_expr: *ast.Expr) SemaError!semantic_types.TypeId {
            const base_type = if (local.kind(context) == .ref) canonicalRefTarget(context, local.type_id) else local.type_id;
            const root_type = canonicalUnwrapOwned(context, base_type);
            if (ownership_owner.exprPathContainsDeref(source_expr) and canonicalTypeNode(context, root_type).* == .raw) {
                return canonicalTypeNode(context, root_type).raw.target;
            }
            return root_type;
        }

        pub fn collectPlaceRootAndSteps(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            expr: *ast.Expr,
            reversed_steps: *std.ArrayListUnmanaged(TakeAstStep),
            failure_message: []const u8,
        ) SemaError!ast.Name {
            var cursor = expr;
            while (true) {
                switch (cursor.*) {
                    .field => |field| {
                        try reversed_steps.append(allocator, .{ .field = field });
                        cursor = field.object;
                    },
                    .index => |index| {
                        try reversed_steps.append(allocator, .{ .index = index });
                        cursor = index.object;
                    },
                    .deref => |deref| {
                        cursor = deref.expr;
                    },
                    .name => |name| return name,
                    else => {
                        try context.diagnostic_context.emitToken(path, firstExprToken(expr), "{s}", .{failure_message});
                        return SemaError.SemanticFailed;
                    },
                }
            }
        }

        pub fn recordTakePlaceIdentity(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            expr: *const sir.Expr,
            binding_id: ?identity.BindingId,
        ) SemaError!void {
            if (binding_id == null) return;
            var metadata = semanticExprMetadata(context, expr) orelse return error.SemanticFailed;
            metadata.checked_place_root = .{ .binding = binding_id.? };
            metadata.checked_place_projections = try buildCheckedPlaceProjections(context, allocator, expr);
            errdefer if (metadata.checked_place_projections) |projections| allocator.free(projections);
            try recordExprMetadata(context, expr, metadata);
        }

        pub fn buildTakeObjectExprFromPath(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            locals: []const LocalBinding,
            local_name: []const u8,
            steps: []const sir.TakePathStep,
        ) SemaError!*sir.Expr {
            const local = findLocal(locals, local_name) orelse return error.SemanticFailed;
            var current_type = if (canonicalTypeKind(context, local.type_id) == .ref)
                canonicalRefTarget(context, local.type_id)
            else
                local.type_id;
            // The link table is reserved once, so recording a link can never fail and
            // every node this function creates is accounted for the moment it exists.
            const chain = try allocator.alloc(*sir.Expr, steps.len + 1);
            var chain_len: usize = 0;
            // Each link owns the link before it, so destroying the deepest link frees
            // the whole chain; the table itself is bookkeeping only.
            errdefer {
                if (chain_len != 0) chain[chain_len - 1].destroy(allocator);
                // From here this function owns every index expression in `steps`: the
                // linked ones are inside the chain, the rest are released with it.
                // chain[0] is the root, so the step recorded in chain[i + 1] is step i.
                const first_unlinked = if (chain_len == 0) 0 else chain_len - 1;
                for (steps[first_unlinked..]) |step| switch (step) {
                    .field => {},
                    .index => |index_expr| index_expr.destroy(allocator),
                };
                allocator.free(chain);
            }
            const root = try allocator.create(sir.Expr);
            root.* = .{ .local = local_name };
            chain[chain_len] = root;
            chain_len += 1;
            var root_typed = makeTypedExprFromId(root, current_type);
            try finalizeAndRecordExprSemantics(context, path, program, current_module, &root_typed);
            // The synthesized take place keeps the same checked root and projection
            // chain a place read lowered through lowerExpr would record.
            try recordTakePlaceIdentity(context, allocator, root, local.binding_id);
            var current = root;
            for (steps) |step| {
                const next = try allocator.create(sir.Expr);
                next.* = .none;
                var linked = false;
                errdefer if (!linked) allocator.destroy(next);
                switch (step) {
                    .field => |field| {
                        const decl_id = field.struct_decl_id orelse return error.SemanticFailed;
                        const decl = lookupStructDeclById(context, program, decl_id) orelse return error.SemanticFailed;
                        const decl_field = lookupStructField(decl, field.field) orelse return error.SemanticFailed;
                        current_type = try structFieldTypeId(context, path, program, decl, decl_field);
                        next.* = .{ .field = .{
                            .object = current,
                            .struct_decl_id = field.struct_decl_id,
                            .struct_name = field.struct_name,
                            .field = field.field,
                        } };
                    },
                    .index => |index| {
                        current_type = switch (canonicalTypeNode(context, canonicalUnwrapOwned(context, current_type)).*) {
                            .array => |array| array.item,
                            .slice => |slice| slice.item,
                            .dense_array, .sparse_array => |item| item,
                            else => return error.SemanticFailed,
                        };
                        next.* = .{ .index = .{
                            .object = current,
                            .index = index,
                        } };
                    },
                }
                chain[chain_len] = next;
                chain_len += 1;
                linked = true;
                var next_typed = makeTypedExprFromId(next, current_type);
                try finalizeAndRecordExprSemantics(context, path, program, current_module, &next_typed);
                try recordTakePlaceIdentity(context, allocator, next, local.binding_id);
                current = next;
            }
            // The chain array is bookkeeping only: the linked nodes are owned by the
            // returned expression once the chain is built.
            allocator.free(chain);
            return current;
        }

        pub fn buildCheckedTakeProjections(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            locals: []const LocalBinding,
            expr: *const sir.Expr,
            result_type_id: semantic_types.TypeId,
        ) SemaError!?[]const sir.CheckedPlaceProjection {
            const local_name: []const u8 = switch (expr.*) {
                .take_path_local => |take| take.local_name,
                .take_index_local => |take| take.local_name,
                .take_index_path_local => |take| take.local_name,
                .ref_path_local => |reference| reference.local_name,
                .ref_index_path_local => |reference| reference.local_name,
                else => return error.SemanticFailed,
            };
            const steps: []const sir.TakePathStep = switch (expr.*) {
                .take_path_local => |take| take.steps,
                .take_index_local => &.{},
                .take_index_path_local => |take| take.steps,
                .ref_path_local => |reference| reference.steps,
                .ref_index_path_local => |reference| reference.steps,
                else => unreachable,
            };
            const final_index: ?*sir.Expr = switch (expr.*) {
                .take_index_local => |take| take.index,
                .take_index_path_local => |take| take.index,
                .ref_index_path_local => |reference| reference.index,
                else => null,
            };
            const reference_path = expr.* == .ref_path_local or expr.* == .ref_index_path_local;
            const local = findLocal(locals, local_name) orelse return error.SemanticFailed;
            var current_type = if (local.kind(context) == .ref) canonicalRefTarget(context, local.type_id) else local.type_id;
            var projections: std.ArrayListUnmanaged(sir.CheckedPlaceProjection) = .empty;
            defer projections.deinit(allocator);
            for (steps) |step| switch (step) {
                .field => |field| {
                    const declaration = field.struct_decl_id orelse return error.SemanticFailed;
                    const struct_decl = lookupStructDeclById(context, program, declaration) orelse return error.SemanticFailed;
                    const decl_field = lookupStructField(struct_decl, field.field) orelse return error.SemanticFailed;
                    current_type = try structFieldTypeId(context, path, program, struct_decl, decl_field);
                    try projections.append(allocator, .{
                        .step = .{ .field = .{ .owner_decl_id = declaration, .name = field.field } },
                        .result_type_id = current_type,
                    });
                },
                .index => |index| {
                    current_type = switch (canonicalTypeNode(context, canonicalUnwrapOwned(context, current_type)).*) {
                        .array => |array| array.item,
                        .dense_array => |item| item,
                        .sparse_array => |item| if (reference_path) try canonicalOptionalTypeId(context, item) else item,
                        .slice => |slice| slice.item,
                        else => return error.SemanticFailed,
                    };
                    try projections.append(allocator, .{
                        .step = .{ .index = if (index.* == .int and index.int.value >= 0)
                            .{ .fixed = index.int.value }
                        else
                            .{ .dynamic = index } },
                        .result_type_id = current_type,
                    });
                },
            };
            if (final_index) |index| {
                current_type = switch (canonicalTypeNode(context, canonicalUnwrapOwned(context, current_type)).*) {
                    .array => |array| array.item,
                    .dense_array => |item| item,
                    .sparse_array => |item| if (reference_path) try canonicalOptionalTypeId(context, item) else item,
                    .slice => |slice| slice.item,
                    else => return error.SemanticFailed,
                };
                try projections.append(allocator, .{
                    .step = .{ .index = if (index.* == .int and index.int.value >= 0)
                        .{ .fixed = index.int.value }
                    else
                        .{ .dynamic = index } },
                    .result_type_id = current_type,
                });
            }
            const expected_type = if (reference_path) canonicalRefTarget(context, result_type_id) else result_type_id;
            if (current_type != expected_type and
                !(reference_path and canonicalTypeNode(context, current_type).* == .owned and
                    canonicalTypeNode(context, current_type).owned == expected_type)) return error.SemanticFailed;
            if (projections.items.len == 0) return null;
            if (reference_path) projections.items[projections.items.len - 1].result_type_id = result_type_id;
            return try projections.toOwnedSlice(allocator);
        }

        /// A borrowed alias or owned borrow names a resolved binding directly in SIR,
        /// so the shortcut lowering paths record the same checked place identity that
        /// `lowerExpr` records for a normal place expression.
        pub fn recordLoweredPlaceIdentity(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            source_expr: *ast.Expr,
            lowered_expr: *const sir.Expr,
        ) SemaError!void {
            const place = resolvePlace(context, program, current_module, globals, locals, source_expr) orelse return;
            if (place.root_kind == .raw_pointee) return;
            var metadata = semanticExprMetadata(context, lowered_expr) orelse return error.SemanticFailed;
            metadata.checked_place_root = if (place.root_binding_id) |binding_id|
                .{ .binding = binding_id }
            else if (place.root_global_id) |global_id|
                .{ .global = global_id }
            else
                null;
            if (metadata.checked_place_root == null) return;
            if (switch (canonicalTypeKind(context, place.root_type_id)) {
                .ref, .slice => true,
                else => false,
            }) metadata.non_owning_place_origin = true;
            metadata.checked_place_projections = if (lowered_expr.* == .ref_path_local or lowered_expr.* == .ref_index_path_local)
                try buildCheckedTakeProjections(context, allocator, path, program, locals, lowered_expr, metadata.type_id)
            else
                try buildCheckedPlaceProjections(context, allocator, lowered_expr);
            errdefer if (metadata.checked_place_projections) |projections| allocator.free(projections);
            if (lowered_expr.* == .ref_field_expr and metadata.checked_place_projections == null) {
                // A hook returned the reference value. The AST's base binding is not
                // the storage reached by that reference, so it cannot root this field.
                metadata.checked_place_root = null;
            }
            try recordExprMetadata(context, lowered_expr, metadata);
        }

        pub fn loweredCasePayloadShape(
            context: *SemaContext,
            source: *const generic_shapes.Shape,
            payload_type: ?semantic_types.TypeId,
        ) SemaError!*const generic_shapes.Shape {
            return try loweredProjectionShape(context, source, payload_type, .payload);
        }

        /// A payload the definition site cannot settle keeps the binder it was projected
        /// from; a payload with a concrete canonical type carries that type.
        pub fn payloadOrigin(context: *SemaContext, payload_type: ?semantic_types.TypeId, subject: TypedExpr) SemaError!?GenericReceiverOrigin {
            if (isDefinitionSiteBinder(context, try subject.canonicalTypeId(context))) return projectedOrigin(subject.generic_origin);
            if (payload_type) |type_id| return receiverOriginFromType(context, type_id);
            return null;
        }

        pub fn appendParamBindingForType(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            module_name: []const u8,
            globals: []const GlobalBinding,
            locals: *std.ArrayListUnmanaged(LocalBinding),
            params: *std.ArrayListUnmanaged(sir.Param),
            name: []const u8,
            name_token: lexer.Token,
            param_type: semantic_types.TypeId,
        ) SemaError!void {
            if (findLocal(locals.items, name) != null) {
                try context.diagnostic_context.emitToken(path, name_token, "duplicate parameter `{s}`", .{name});
                return SemaError.SemanticFailed;
            }

            const param_provenance = try rootedBorrowProvenanceForType(context, path, program, module_name, param_type, .param, name);
            const binding_id = try nextBindingId(context);
            // The canonical parameter type names every binder the parameter stands for,
            // so the body's join of parameter origins needs no separate syntax walk.
            const param_shape = try shapeFromCanonicalType(context, param_type, false);
            try locals.append(allocator, .{
                .name = name,
                .binding_id = binding_id,
                .declaration_token = name_token,
                .generic_shape = param_shape,
                .generic_origin = receiverOriginFromType(context, param_type),
                .borrowed_place = try borrowedPlaceDependencyForStoredValue(context, path, program, module_name, globals, locals.items, null, param_type, param_provenance),
                .provenance = param_provenance,
                .type_id = param_type,
                .is_param = true,
                .is_mutable = false,
                .is_for_binding = false,
                .is_unavailable = false,
                .projection_origin = null,
                .is_scoped_alloc_value = false,
                .scoped_alloc_origin = null,
                .scope_depth = context.function_state.block_depth,
            });
            try params.append(allocator, .{
                .name = name,
                .type_id = param_type,
                .binding_id = binding_id,
            });
        }

        pub fn checkedIfPayloadCase(context: *SemaContext, program: ast.Program, kind: sir.IfKind, subject_type_id: ?semantic_types.TypeId, maybe_union_id: ?identity.DeclId, maybe_case_name: ?[]const u8) ?sir.CheckedPayloadCase {
            return switch (kind) {
                .optional_some => .optional_some,
                .union_case => blk: {
                    if (maybe_union_id) |union_id| {
                        const decl = lookupUnionDeclById(context, program, union_id) orelse break :blk null;
                        const ordinal = unionFieldOrdinal(decl.fields, maybe_case_name orelse break :blk null) orelse break :blk null;
                        break :blk .{ .union_field = .{ .owner_decl_id = union_id, .ordinal = ordinal } };
                    }
                    const subject_type = subject_type_id orelse break :blk null;
                    if (canonicalTypeNode(context, subject_type).* != .result) break :blk null;
                    break :blk .{ .result = language_contracts.resolveResultCase(maybe_case_name orelse break :blk null) orelse break :blk null };
                },
                else => null,
            };
        }

        const TagNarrowCase = struct {
            union_decl_id: ?identity.DeclId = null,
            case_name: []const u8,
            capture_type: ?semantic_types.TypeId = null,
        };

        pub fn resolveTagNarrowCase(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            subject: TypedExpr,
            is_test: ast.IsTestExpr,
        ) SemaError!TagNarrowCase {
            _ = current_module;
            const subject_type_id = if (subject.kind(context) == .ref) canonicalRefTarget(context, subject.type_id) else subject.type_id;
            switch (canonicalTypeNode(context, subject_type_id).*) {
                .result => {
                    try context.diagnostic_context.emitToken(path, is_test.token, "result case patterns are unavailable; use `catch (code) {{ ... }}`", .{});
                    return SemaError.SemanticFailed;
                },
                .nominal => |nominal| {
                    if (nominal.kind != .@"union") {
                        try context.diagnostic_context.emitToken(path, is_test.token, "`is .tag` requires a union or result value", .{});
                        return SemaError.SemanticFailed;
                    }
                    const decl_id = canonicalNominalDeclId(context, subject_type_id) orelse return error.SemanticFailed;
                    const decl = lookupUnionDeclById(context, program, decl_id) orelse return error.SemanticFailed;
                    const union_field = findUnionField(decl.fields, is_test.case_name.?) orelse {
                        try context.diagnostic_context.emitToken(path, is_test.token, "union `{s}` has no case `{s}`", .{ decl.name, is_test.case_name.? });
                        return SemaError.SemanticFailed;
                    };
                    const capture_type = if (is_test.capture_name != null) blk: {
                        const type_name = union_field.type_name orelse {
                            try context.diagnostic_context.emitToken(path, is_test.token, "union case `{s}.{s}` does not carry a payload", .{ decl.name, is_test.case_name.? });
                            return SemaError.SemanticFailed;
                        };
                        break :blk try parseCanonicalType(context, path, program, decl.module_name, type_name);
                    } else null;
                    return .{
                        .union_decl_id = decl_id,
                        .case_name = is_test.case_name.?,
                        .capture_type = capture_type,
                    };
                },
                else => {
                    try context.diagnostic_context.emitToken(path, is_test.token, "`is .tag` requires a union or result value", .{});
                    return SemaError.SemanticFailed;
                },
            }
        }

        pub fn buildInterpolationProjectionExpr(allocator: std.mem.Allocator, hole: ast.InterpolationHole) SemaError!*ast.Expr {
            var expr = try allocator.create(ast.Expr);
            errdefer expr.destroy(allocator);
            expr.* = .{ .name = hole.base };
            for (hole.fields) |field| {
                const parent = try allocator.create(ast.Expr);
                errdefer parent.destroy(allocator);
                parent.* = .{ .field = .{
                    .object = expr,
                    .field = field.text,
                    .field_token = field.token,
                } };
                expr = parent;
            }
            return expr;
        }

        pub fn interpolationFormatToDebugFormat(format: ast.InterpolationFormat) sir.DebugFormat {
            return switch (format) {
                .direct => .direct,
                .decimal => .decimal,
                .binary => .binary,
                .octal => .octal,
                .hex_lower => .hex_lower,
                .hex_upper => .hex_upper,
            };
        }

        const FieldAliasPathStep = struct {
            field: []const u8,
            field_token: lexer.Token,
        };

        const FieldAliasPath = struct {
            base: ast.Name,
            steps: []const FieldAliasPathStep,
        };

        pub fn collectFieldAliasPath(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            expr: *ast.Expr,
        ) SemaError!FieldAliasPath {
            var reversed: std.ArrayListUnmanaged(FieldAliasPathStep) = .empty;
            errdefer reversed.deinit(allocator);

            var current = expr;
            while (true) {
                switch (current.*) {
                    .field => |field| {
                        try reversed.append(allocator, .{
                            .field = field.field,
                            .field_token = field.field_token,
                        });
                        current = field.object;
                    },
                    .name => |name| {
                        const steps = try allocator.alloc(FieldAliasPathStep, reversed.items.len);
                        errdefer allocator.free(steps);
                        for (reversed.items, 0..) |step, i| {
                            steps[reversed.items.len - 1 - i] = step;
                        }
                        reversed.deinit(allocator);
                        return .{
                            .base = name,
                            .steps = steps,
                        };
                    },
                    else => {
                        try context.diagnostic_context.emitToken(path, firstExprToken(expr), "field alias path is not addressable by this projection form", .{});
                        return SemaError.SemanticFailed;
                    },
                }
            }
        }

        pub fn sequenceRepeatCount(context: *SemaContext, path: []const u8, repeat: ast.SequenceRepeat) SemaError!usize {
            switch (repeat.count.*) {
                .int => |literal| {
                    if (literal.value < 0) {
                        try context.diagnostic_context.emitToken(path, literal.token, "sequence repeat count cannot be negative", .{});
                        return SemaError.SemanticFailed;
                    }
                    return @intCast(literal.value);
                },
                .name => |name| {
                    if (genericArrayLenForName(context.function_state.current_generic_params, context.function_state.current_generic_args, name.text)) |len| return len;
                    try context.diagnostic_context.emitToken(path, name.token, "unknown sequence repeat count `{s}`", .{name.text});
                    return SemaError.SemanticFailed;
                },
                else => {
                    try context.diagnostic_context.emitToken(path, firstExprToken(repeat.count), "sequence repeat count must be an integer literal or `usize` const generic parameter", .{});
                    return SemaError.SemanticFailed;
                },
            }
        }

        pub fn repeatedSequenceItems(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            repeat: ast.SequenceRepeat,
        ) SemaError![]*ast.Expr {
            const count = try sequenceRepeatCount(context, path, repeat);
            const total_len = std.math.mul(usize, repeat.items.len, count) catch {
                try context.diagnostic_context.emitToken(path, repeat.token, "sequence repeat result is too large", .{});
                return SemaError.SemanticFailed;
            };
            var items = try allocator.alloc(*ast.Expr, total_len);
            var out_index: usize = 0;
            var repeat_index: usize = 0;
            while (repeat_index < count) {
                for (repeat.items) |item| {
                    items[out_index] = item;
                    out_index = out_index + 1;
                }
                repeat_index = repeat_index + 1;
            }
            return items;
        }

        pub fn unionFieldOrdinal(fields: []const ast.UnionField, name: []const u8) ?u32 {
            for (fields, 0..) |field, index| {
                if (std.mem.eql(u8, field.name, name)) return @intCast(index);
            }
            return null;
        }

        pub fn switchCoversCase(cases: []const ast.SwitchCase, type_name: ?[]const u8, case_name: []const u8) bool {
            for (cases) |case| {
                if (case.type_name == null and std.mem.eql(u8, case.case_name, case_name)) return true;
                if (case.type_name != null and type_name != null and std.mem.eql(u8, case.type_name.?, type_name.?) and std.mem.eql(u8, case.case_name, case_name)) return true;
            }
            return false;
        }

        const ResolvedUnionSwitchCase = struct {
            case_name: []const u8,
            payload_name: ?[]const u8,
            payload_type_id: ?semantic_types.TypeId,
            ordinal: u32,
        };

        pub fn resolveInlineErrorUnionSwitchCase(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            members: []const semantic_types.TypeId,
            case: ast.SwitchCase,
        ) SemaError!ResolvedUnionSwitchCase {
            const variant = case.type_variant orelse {
                try context.diagnostic_context.emitToken(path, case.token, "switch on inline error union requires enum type labels", .{});
                return SemaError.SemanticFailed;
            };
            const case_type = try parseType(context, path, program, current_module, variant);
            for (members, 0..) |member, ordinal| {
                if (member != case_type) continue;
                const case_name = try formatCanonicalTypeDisplay(context, member);
                errdefer context.allocator.free(case_name);
                try context.output.generated_strings.append(allocator, case_name);
                return .{
                    .case_name = case_name,
                    .payload_name = case.payload_name,
                    .payload_type_id = member,
                    .ordinal = @intCast(ordinal),
                };
            }
            try context.diagnostic_context.emitToken(path, case.token, "enum type is not a member of this inline error union", .{});
            return SemaError.SemanticFailed;
        }

        pub fn resolveUnionSwitchCase(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            union_name: []const u8,
            decl: ast.UnionDecl,
            case: ast.SwitchCase,
        ) SemaError!ResolvedUnionSwitchCase {
            switch (decl.kind) {
                .named_cases => {
                    if (case.type_variant != null or case.type_name != null) {
                        try context.diagnostic_context.emitToken(path, case.token, "switch on union `{s}` requires `.tag` case labels", .{union_name});
                        return SemaError.SemanticFailed;
                    }
                    const union_field = findUnionField(decl.fields, case.case_name) orelse {
                        try context.diagnostic_context.emitToken(path, case.token, "union `{s}` has no case `{s}`", .{ union_name, case.case_name });
                        return SemaError.SemanticFailed;
                    };
                    const payload_type = if (union_field.type_name) |type_name| try parseType(context, path, program, decl.module_name, type_name) else null;
                    if (case.payload_name != null and payload_type == null) {
                        try context.diagnostic_context.emitToken(path, case.token, "union case `{s}.{s}` does not carry a payload", .{ union_name, case.case_name });
                        return SemaError.SemanticFailed;
                    }
                    return .{
                        .case_name = case.case_name,
                        .payload_name = case.payload_name,
                        .payload_type_id = payload_type,
                        .ordinal = unionFieldOrdinal(decl.fields, case.case_name) orelse return error.SemanticFailed,
                    };
                },
                .type_union => {
                    const variant = case.type_variant orelse {
                        try context.diagnostic_context.emitToken(path, case.token, "switch on type union `{s}` requires variant type labels", .{union_name});
                        return SemaError.SemanticFailed;
                    };
                    if (case.type_name != null) {
                        try context.diagnostic_context.emitToken(path, case.token, "switch on type union `{s}` requires variant type labels", .{union_name});
                        return SemaError.SemanticFailed;
                    }
                    const case_type = try parseType(context, path, program, current_module, variant);
                    for (decl.variants, 0..) |decl_variant, ordinal| {
                        const variant_type = try parseType(context, path, program, decl.module_name, decl_variant);
                        if (typeEqual(context, variant_type, case_type)) {
                            const case_name = try formatTypeDisplay(context, variant_type);
                            try context.output.generated_strings.append(allocator, case_name);
                            return .{
                                .case_name = case_name,
                                .payload_name = case.payload_name,
                                .payload_type_id = variant_type,
                                .ordinal = @intCast(ordinal),
                            };
                        }
                    }
                    const display = try formatTypeDisplay(context, case_type);
                    defer allocator.free(display);
                    try context.diagnostic_context.emitToken(path, case.token, "type union `{s}` has no variant `{s}`", .{ union_name, display });
                    return SemaError.SemanticFailed;
                },
            }
        }

        pub fn switchCoversTypeUnionVariant(context: *SemaContext, path: []const u8, program: ast.Program, current_module: []const u8, cases: []const ast.SwitchCase, decl: ast.UnionDecl, variant: ast.TypeName) SemaError!bool {
            const variant_type = try parseType(context, path, program, decl.module_name, variant);
            for (cases) |case| {
                const case_variant = case.type_variant orelse continue;
                const case_type = try parseType(context, path, program, current_module, case_variant);
                if (typeEqual(context, variant_type, case_type)) return true;
            }
            return false;
        }

        /// A definition-site body is analyzed, never emitted: a binder has no
        /// representation in generated code. Everything the trial lowering produced is
        /// dropped so it cannot reach the emitted module or the generated code.
        pub fn discardDefinitionSiteArtifacts(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            metadata_base: usize,
            function_base: usize,
            struct_base: usize,
        ) void {
            while (context.expr_metadata.items.len > metadata_base) {
                const entry = context.expr_metadata.pop() orelse break;
                _ = context.expr_metadata_index.remove(entry.expr);
                if (entry.metadata.checked_place_projections) |projections| allocator.free(projections);
            }
            while (context.generic.instantiated_functions.items.len > function_base) {
                const function = context.generic.instantiated_functions.pop() orelse break;
                function.deinit(allocator);
            }
            while (context.generic.instantiated_structs.items.len > struct_base) {
                const decl = context.generic.instantiated_structs.pop() orelse break;
                decl.deinit(allocator);
            }
        }

        /// B4: lower every generic declaration body against its own binders, so method
        /// admission and the checked body flow both happen at the definition site before
        /// any witness specializes the declaration. Bodies the lowering cannot model yet
        /// (a const-value binder has no type to stand in for it, for example) are
        /// recorded as gaps and keep their declaration-time requirement records.
        /// When CYNA_SEMA_TRACE is set, the definition-site pass reports every generic
        /// body it attempts and why an attempt did not verify. This is a measurement
        /// aid for closing the B4 coverage gap, not a language feature.
        pub fn definitionSiteTrace(kind: []const u8, owner: ?[]const u8, name: []const u8, detail: []const u8) void {
            if (std.c.getenv("CYNA_SEMA_TRACE") == null) return;
            std.debug.print("generic-definition {s} {s}.{s} {s}\n", .{ kind, owner orelse "", name, detail });
        }

        /// A method of a generic struct, or of an impl for a generic struct, is lowered
        /// against the placeholder instantiation of that struct: its fields, layouts,
        /// and materialized conformances have to exist before the body is lowered.
        pub fn registerDefinitionSiteReceiverLayout(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            module_name: []const u8,
            generic_params: []const ast.GenericParam,
            receiver_struct: ast.StructDecl,
        ) SemaError!void {
            if (receiver_struct.type_params.len == 0 or generic_params.len < receiver_struct.type_params.len) return;
            const args = try allocator.alloc(semantic_types.GenericArgument, receiver_struct.type_params.len);
            defer allocator.free(args);
            for (args, 0..) |*arg, ordinal| {
                const type_id = try canonicalGenericParameterTypeId(context, module_name, generic_params, @intCast(ordinal)) orelse return;
                arg.* = .{ .type = type_id };
            }
            _ = try instantiateGenericStructWithTypeArgs(context, path, program, receiver_struct, args);
        }

        /// A generic body can name an instantiation of another generic struct whose
        /// layout no witness has created yet: the placeholder receiver layout covers the
        /// receiver only. Materialize the layout the body names, with the impl
        /// conformances of that instantiation, so method lookup can resolve it.
        pub fn materializeDefinitionSiteStructInstance(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            type_id: semantic_types.TypeId,
        ) void {
            const node = canonicalTypeNode(context, type_id);
            if (node.* != .generic_instance) return;
            const instance = node.generic_instance;
            if (instance.kind != .@"struct") return;
            const base_decl = findAstStructDeclById(context, program, instance.base_decl_id) orelse return;
            _ = instantiateGenericStructWithTypeArgs(context, path, program, base_decl, instance.args) catch return;
        }

        /// A definition-site attempt that stopped lowering because the body reached a
        /// generic method use its own binders cannot authorize: the diagnostic the
        /// attempt recorded is replayed to the caller's diagnostics and the declaration
        /// fails. Returns false when the attempt stopped for some other reason.
        pub fn replayGenericAdmissionFailure(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            saved_diagnostics: diagnostics.Context,
            lowered_owner: ?[]const u8,
            lowered_name: []const u8,
            metadata_base: usize,
            function_base: usize,
            struct_base: usize,
        ) SemaError!bool {
            const failure = context.generic.generic_admission_failure orelse return false;
            context.diagnostic_context = saved_diagnostics;
            try context.diagnostic_context.emitTokenWith(failure.path, failure.token, .{
                .code = failure.code,
                .labels = failure.labels,
                .help = failure.help,
            }, "{s}", .{failure.message});
            definitionSiteTrace("gap-admission", lowered_owner, lowered_name, failure.message);
            discardDefinitionSiteArtifacts(context, allocator, metadata_base, function_base, struct_base);
            return true;
        }

        pub fn lowerDefinitionSiteBody(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            globals: []const GlobalBinding,
            structs: []const sir.StructDecl,
            unions: []const sir.UnionDecl,
            function: ast.Function,
            generic_params: []const ast.GenericParam,
            lowered_owner: ?[]const u8,
            lowered_name: []const u8,
            receiver_struct: ?ast.StructDecl,
            placeholder_struct_base: usize,
        ) SemaError!void {
            definitionSiteTrace("attempt", lowered_owner, lowered_name, "");
            if (context.generic.generic_admission_failure) |failure| failure.deinit(allocator);
            context.generic.generic_admission_failure = null;
            defer {
                if (context.generic.generic_admission_failure) |failure| failure.deinit(allocator);
                context.generic.generic_admission_failure = null;
            }
            const placeholder_args = try placeholderGenericArgs(context, allocator, function.module_name, generic_params);
            if (placeholder_args == null) {
                definitionSiteTrace("gap-placeholder", lowered_owner, lowered_name, "binder has no stand-in type");
                return;
            }
            const args = placeholder_args.?;
            defer allocator.free(args);

            const saved_params = context.function_state.current_generic_params;
            const saved_args = context.function_state.current_generic_args;
            context.function_state.current_generic_params = generic_params;
            context.function_state.current_generic_args = args;
            defer {
                context.function_state.current_generic_params = saved_params;
                context.function_state.current_generic_args = saved_args;
            }

            const metadata_base = context.expr_metadata.items.len;
            const function_base = context.generic.instantiated_functions.items.len;
            const saved_diagnostics = context.diagnostic_context;
            var capture: std.ArrayListUnmanaged(u8) = .empty;
            defer capture.deinit(allocator);
            context.diagnostic_context = if (std.c.getenv("CYNA_SEMA_TRACE") != null)
                diagnostics.Context.capturing(allocator, &capture)
            else
                diagnostics.Context.discarded();
            // The receiver's placeholder instantiation is shared by every method of a
            // generic struct, so it outlives the attempt that created it and is freed
            // once when the definition-site pass finishes.
            const receiver_struct_base = context.generic.instantiated_structs.items.len;
            if (receiver_struct) |decl| {
                registerDefinitionSiteReceiverLayout(context, allocator, path, program, function.module_name, generic_params, decl) catch |err| {
                    if (err == error.OutOfMemory) {
                        context.diagnostic_context = saved_diagnostics;
                        return error.OutOfMemory;
                    }
                    // A receiver layout the checker cannot model yet is not usable, so
                    // release the partial one and let the body fall back to the ordinary
                    // lowering path; the attempt is then recorded as a coverage gap.
                    while (context.generic.instantiated_structs.items.len > receiver_struct_base) {
                        const partial = context.generic.instantiated_structs.pop() orelse break;
                        partial.deinit(allocator);
                    }
                    var detail: [512]u8 = undefined;
                    const first_line_end = std.mem.indexOfScalar(u8, capture.items, '\n') orelse capture.items.len;
                    const detail_text = std.fmt.bufPrint(&detail, "{s} {s}", .{ @errorName(err), capture.items[0..first_line_end] }) catch "";
                    definitionSiteTrace("gap-receiver", lowered_owner, lowered_name, detail_text);
                    if (try replayGenericAdmissionFailure(context, allocator, saved_diagnostics, lowered_owner, lowered_name, metadata_base, function_base, receiver_struct_base)) return error.SemanticFailed;
                };
            }
            const struct_base = context.generic.instantiated_structs.items.len;

            const lowered = lowerFunctionSpecialized(context, allocator, path, program, globals, function, lowered_owner, lowered_name);
            context.diagnostic_context = saved_diagnostics;

            const body = lowered catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    if (try replayGenericAdmissionFailure(context, allocator, saved_diagnostics, lowered_owner, lowered_name, metadata_base, function_base, struct_base)) return error.SemanticFailed;
                    const first_line_end = std.mem.indexOfScalar(u8, capture.items, '\n') orelse capture.items.len;
                    const detail_len = @min(first_line_end, 400);
                    var detail: [512]u8 = undefined;
                    const detail_text = std.fmt.bufPrint(&detail, "{s} {s}", .{ @errorName(err), capture.items[0..detail_len] }) catch "";
                    definitionSiteTrace("gap-lowering", lowered_owner, lowered_name, detail_text);
                    discardDefinitionSiteArtifacts(context, allocator, metadata_base, function_base, struct_base);
                    return;
                },
            };

            // The trial body owns every expression the attempt lowered. If the checked
            // flow cannot be completed for it, the body is released here instead of
            // leaking until the whole compilation aborts.
            var body_owned = true;
            errdefer if (body_owned) body.deinit(allocator);

            // Placeholder specializations the receiver and the body touched are lowered
            // only so the checked flow can resolve the layouts the body names, then
            // discarded. The receiver's own placeholder layout was registered before
            // this attempt, so it starts at the pass's placeholder base.
            var definition_structs: std.ArrayListUnmanaged(sir.StructDecl) = .empty;
            defer {
                for (definition_structs.items) |decl| decl.deinit(allocator);
                definition_structs.deinit(allocator);
            }
            for (context.generic.instantiated_structs.items[placeholder_struct_base..]) |decl| {
                const lowered_layout = try lowerInstantiatedStruct(context, decl);
                errdefer lowered_layout.deinit(allocator);
                try definition_structs.append(allocator, lowered_layout);
            }
            // The emitted layouts plus the placeholder layouts the body names are the
            // receiver layouts the checked flow can resolve.
            const layouts = try allocator.alloc(sir.StructDecl, structs.len + definition_structs.items.len);
            defer allocator.free(layouts);
            @memcpy(layouts[0..structs.len], structs);
            @memcpy(layouts[structs.len..], definition_structs.items);

            const metadata_count = context.expr_metadata.items.len - metadata_base;
            const snapshot = try allocator.alloc(sir.ExprMetadataEntry, metadata_count);
            defer allocator.free(snapshot);
            @memcpy(snapshot, context.expr_metadata.items[metadata_base..]);

            var gap_scratch: [256]u8 = undefined;
            const body_gap = try generic_definition_body_check.firstGap(allocator, &context.canonical.types.?, context.generic.generic_contract_functions.items, body, snapshot, layouts, unions, &gap_scratch);
            if (body_gap == null) {
                definitionSiteTrace("verified", lowered_owner, lowered_name, "");
                // The checked body that verified is the record of every operation and
                // method use this declaration makes, and it is the only admission
                // authority a generic declaration has.
                try context.generic.generic_definition_bodies.append(allocator, body);
                body_owned = false;
            } else {
                definitionSiteTrace("gap-checked", lowered_owner, lowered_name, body_gap.?);
                body.deinit(allocator);
                body_owned = false;
            }
            discardDefinitionSiteArtifacts(context, allocator, metadata_base, function_base, struct_base);
        }

        pub fn lowerGenericDefinitionBodies(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            globals: []const GlobalBinding,
            structs: []const sir.StructDecl,
            unions: []const sir.UnionDecl,
        ) SemaError!void {
            const allocator = context.allocator;
            // Placeholder receiver layouts created below are trial artifacts: they are
            // shared between attempts, then released before the module is emitted.
            const placeholder_struct_base = context.generic.instantiated_structs.items.len;
            for (program.functions) |function| {
                if (function.type_params.len == 0) continue;
                try lowerDefinitionSiteBody(context, allocator, path, program, globals, structs, unions, function, function.type_params, function.owner, function.name, null, placeholder_struct_base);
            }
            for (program.structs) |decl| {
                for (decl.methods) |method| {
                    if (decl.type_params.len == 0 and method.type_params.len == 0) continue;
                    const params = try allocator.alloc(ast.GenericParam, decl.type_params.len + method.type_params.len);
                    defer allocator.free(params);
                    @memcpy(params[0..decl.type_params.len], decl.type_params);
                    @memcpy(params[decl.type_params.len..], method.type_params);
                    try lowerDefinitionSiteBody(context, allocator, path, program, globals, structs, unions, method, params, method.owner orelse decl.name, method.name, decl, placeholder_struct_base);
                }
            }
            for (program.impls) |decl| {
                for (decl.methods) |method| {
                    if (decl.type_params.len == 0 and method.type_params.len == 0) continue;
                    const params = try allocator.alloc(ast.GenericParam, decl.type_params.len + method.type_params.len);
                    defer allocator.free(params);
                    @memcpy(params[0..decl.type_params.len], decl.type_params);
                    @memcpy(params[decl.type_params.len..], method.type_params);
                    const receiver_struct = findStruct(context, program, decl.module_name, decl.type_name.name);
                    try lowerDefinitionSiteBody(context, allocator, path, program, globals, structs, unions, method, params, decl.method_owner, method.name, receiver_struct, placeholder_struct_base);
                }
            }
            while (context.generic.instantiated_structs.items.len > placeholder_struct_base) {
                const decl = context.generic.instantiated_structs.pop() orelse break;
                decl.deinit(allocator);
            }
        }

        /// B4: the checked body flow is the authority for a lowered declaration that
        /// evaluates a generic method use. The flow has to reach every recorded use,
        /// settle each use's stable identity exactly once, settle the receiver the use
        /// is evaluated against, and settle a result of the declared type. Definition-site
        /// (uninstantiated) generic bodies are never lowered to SIR, so their
        /// declaration-time requirement records are still produced by the source shape walk.
        pub fn verifyCheckedGenericMethodBodies(
            context: *SemaContext,
            path: []const u8,
            functions: []const sir.Function,
            structs: []const sir.StructDecl,
            unions: []const sir.UnionDecl,
            metadata: []const sir.ExprMetadataEntry,
        ) SemaError!void {
            const allocator = context.allocator;
            const types = generic_origins.TypeAdapter{ .types = &context.canonical.types.? };
            for (functions) |*function| {
                var present: std.ArrayListUnmanaged(u32) = .empty;
                defer present.deinit(allocator);
                try sir_method_use_ids.collect(allocator, function, &present);
                if (present.items.len == 0) continue;
                var uses: std.ArrayListUnmanaged(generic_origins.MethodUse) = .empty;
                defer uses.deinit(allocator);
                const report = generic_origins.analyzeBody(allocator, types, functions, function, metadata, structs, unions, &uses) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.UnverifiedMethodReceiver => {
                        try context.diagnostic_context.emitToken(path, function.debug_token, "generic method use in `{s}` is evaluated against a receiver the checked body flow proves empty", .{function.name});
                        return error.SemanticFailed;
                    },
                    error.MissingMethodUseIdentity, error.MissingMethodUseSignature => {
                        try context.diagnostic_context.emitToken(path, function.debug_token, "generic method use in `{s}` has no checked method-use identity or signature", .{function.name});
                        return error.SemanticFailed;
                    },
                    else => {
                        // Recorded B4 shape gap: the checked flow cannot model this body
                        // yet, so its admission still comes from the definition-site
                        // requirement records. Each gap is listed in the coverage ledger.
                        continue;
                    },
                };
                const issue = try method_use_settlement.firstIssue(allocator, present.items, uses.items, report, function.return_type_id);
                if (issue) |found| {
                    switch (found) {
                        .count_mismatch => |counts| try context.diagnostic_context.emitToken(path, function.debug_token, "generic method use in `{s}` is not reached by the checked body flow ({d} of {d} verified)", .{ function.name, counts.observed, counts.recorded }),
                        .missing_use_id => try context.diagnostic_context.emitToken(path, function.debug_token, "generic method use in `{s}` has no checked method-use identity", .{function.name}),
                        .not_once => |settlement| try context.diagnostic_context.emitToken(path, function.debug_token, "generic method use {d} in `{s}` is settled {d} times by the checked body flow", .{ settlement.use_id, function.name, settlement.count }),
                        .return_type_mismatch => try context.diagnostic_context.emitToken(path, function.debug_token, "generic method use in `{s}` settles a result of a different type than declared", .{function.name}),
                    }
                    return error.SemanticFailed;
                }
            }
        }

        pub fn lowerFunction(context: *SemaContext, path: []const u8, program: ast.Program, globals: []const GlobalBinding, function: ast.Function) SemaError!sir.Function {
            return lowerFunctionSpecialized(context, context.allocator, path, program, globals, function, function.owner, function.name);
        }

        pub fn lowerFunctionNamed(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            globals: []const GlobalBinding,
            function: ast.Function,
            lowered_name: []const u8,
        ) SemaError!sir.Function {
            return lowerFunctionSpecialized(context, allocator, path, program, globals, function, function.owner, lowered_name);
        }

        /// Inline tests return `void!TestError` from the compiler-shipped
        /// std.testing module. Bind that identity through compiler ownership
        /// so an unrelated module cannot supply a same-named enum.
        fn compilerTestErrorEnum(program: ast.Program) ?ast.EnumDecl {
            for (program.module_infos) |info| {
                if (!info.compiler_owned) continue;
                if (!std.mem.eql(u8, info.name, "std.testing") and
                    !std.mem.endsWith(u8, info.name, ".testing")) continue;
                if (lookup.findEnumInModule(program, info.name, "TestError")) |decl| return decl;
            }
            return findEnumAny(program, "TestError");
        }

        pub fn lowerInlineTestFunction(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            globals: []const GlobalBinding,
            inline_test: ast.InlineTest,
            lowered_name: []const u8,
            decl_id: identity.DeclId,
        ) SemaError!sir.Function {
            const allocator = context.allocator;
            const saved_active_source_decl_id = context.function_state.active_source_decl_id;
            const saved_active_return_decl_id = context.function_state.active_return_decl_id;
            context.function_state.active_source_decl_id = decl_id;
            context.function_state.active_return_decl_id = decl_id;
            defer {
                context.function_state.active_source_decl_id = saved_active_source_decl_id;
                context.function_state.active_return_decl_id = saved_active_return_decl_id;
            }
            var locals: std.ArrayListUnmanaged(LocalBinding) = .empty;
            defer locals.deinit(allocator);

            const test_error_decl = compilerTestErrorEnum(program) orelse return error.SemanticFailed;
            const test_error_decl_id = maybeRegisteredDeclId(context, test_error_decl.module_name, null, test_error_decl.name, .@"enum") orelse return error.SemanticFailed;
            const interner = if (context.canonical.types) |*value| value else return error.SemanticFailed;
            const test_error_type = try internCanonicalNode(interner, .{ .nominal = .{
                .kind = .@"enum",
                .decl_id = test_error_decl_id,
            } });
            const return_type = try canonicalResultTypeId(context, try canonicalPrimitiveTypeId(context, .void), test_error_type);
            var body_list: std.ArrayListUnmanaged(sir.Stmt) = .empty;
            errdefer {
                for (body_list.items) |stmt| stmt.deinit(allocator);
                body_list.deinit(allocator);
            }

            const body = try lowerBlock(context, allocator, path, program, inline_test.module_name, globals, return_type, &locals, inline_test.body);
            try body_list.appendSlice(allocator, body);
            allocator.free(body);

            const ok_expr = try allocator.create(sir.Expr);
            ok_expr.* = .{ .union_case = .{
                .union_name = language_contracts.result_type_name,
                .case_name = sir.ResultCase.ok.sourceName(),
                .result_case = .ok,
                .value = null,
                .result_ok_type_id = canonicalTypeNode(context, return_type).result.ok,
                .result_err_type_id = canonicalTypeNode(context, return_type).result.err,
            } };
            var ok_typed = makeTypedExprFromId(ok_expr, return_type);
            try finalizeAndRecordExprSemantics(context, path, program, inline_test.module_name, &ok_typed);
            try recordExprSink(context, ok_expr, .@"return");
            try body_list.append(allocator, .{ .@"return" = ok_expr });

            const final_body = try body_list.toOwnedSlice(allocator);
            errdefer {
                for (final_body) |stmt| stmt.deinit(allocator);
                allocator.free(final_body);
            }

            return .{
                .module_name = inline_test.module_name,
                .is_test_entry = true,
                .owner = null,
                .name = lowered_name,
                .params = try allocator.alloc(sir.Param, 0),
                .return_type_id = return_type,
                .debug_token = inline_test.name_token,
                .body = final_body,
            };
        }

        pub fn lowerFunctionSpecialized(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            globals: []const GlobalBinding,
            function: ast.Function,
            lowered_owner: ?[]const u8,
            lowered_name: []const u8,
        ) SemaError!sir.Function {
            var phase: @import("../session.zig").Scope = if (context.options.timing_session) |timing_session| timing_session.start("sema.function.setup", &.{}) else .{};
            defer phase.end();
            errdefer phase.endError();
            const saved_unchecked_depth = context.function_state.unchecked_depth;
            const saved_scoped_alloc_depth = context.function_state.scoped_alloc_depth;
            const saved_scoped_alloc_region_depth = context.function_state.scoped_alloc_region_depth;
            const saved_block_depth = context.function_state.block_depth;
            const saved_loop_depth = context.function_state.loop_depth;
            const saved_switch_yield = context.function_state.active_switch_yield;
            const saved_active_isolated_function = context.function_state.active_isolated_function;
            const saved_active_source_decl_id = context.function_state.active_source_decl_id;
            const saved_active_return_decl_id = context.function_state.active_return_decl_id;
            const saved_expected_return_token = context.function_state.expected_return_token;
            const saved_expected_return_path = context.function_state.expected_return_path;
            const saved_expected_type_origin = context.function_state.expected_type_origin;
            context.function_state.unchecked_depth = 0;
            context.function_state.scoped_alloc_depth = 0;
            context.function_state.scoped_alloc_region_depth = null;
            context.function_state.block_depth = 0;
            context.function_state.loop_depth = 0;
            context.function_state.active_switch_yield = null;
            context.function_state.active_isolated_function = if (function.is_isolated) &function else null;
            context.function_state.active_source_decl_id = maybeRegisteredDeclId(context, function.module_name, function.owner, function.name, .function);
            context.function_state.active_return_decl_id = maybeRegisteredDeclId(context, function.module_name, lowered_owner, lowered_name, .function) orelse context.function_state.active_source_decl_id;
            context.function_state.expected_return_token = if (function.return_type) |type_name| type_name.token else function.name_token;
            context.function_state.expected_return_path = moduleSourcePath(program, function.module_name, path);
            context.function_state.expected_type_origin = null;
            defer {
                context.function_state.unchecked_depth = saved_unchecked_depth;
                context.function_state.scoped_alloc_depth = saved_scoped_alloc_depth;
                context.function_state.scoped_alloc_region_depth = saved_scoped_alloc_region_depth;
                context.function_state.block_depth = saved_block_depth;
                context.function_state.loop_depth = saved_loop_depth;
                context.function_state.active_switch_yield = saved_switch_yield;
                context.function_state.active_isolated_function = saved_active_isolated_function;
                context.function_state.active_source_decl_id = saved_active_source_decl_id;
                context.function_state.active_return_decl_id = saved_active_return_decl_id;
                context.function_state.expected_return_token = saved_expected_return_token;
                context.function_state.expected_return_path = saved_expected_return_path;
                context.function_state.expected_type_origin = saved_expected_type_origin;
            }

            const return_type = try resolvedFunctionReturnType(context, path, program, function, context.function_state.current_generic_params, context.function_state.current_generic_args);
            var locals: std.ArrayListUnmanaged(LocalBinding) = .empty;
            defer locals.deinit(allocator);

            var params: std.ArrayListUnmanaged(sir.Param) = .empty;
            errdefer params.deinit(allocator);

            for (function.params) |param| {
                const param_type = try parseCanonicalType(context, path, program, function.module_name, param.type_name);
                if (findLocal(locals.items, param.name) != null) {
                    try context.diagnostic_context.emitToken(path, param.name_token, "duplicate parameter `{s}`", .{param.name});
                    return SemaError.SemanticFailed;
                }

                const param_provenance = try rootedBorrowProvenanceForType(context, path, program, function.module_name, param_type, .param, param.name);
                const param_shape = try shapeFromCanonicalType(context, param_type, false);
                const binding_id = try nextBindingId(context);
                try locals.append(allocator, .{
                    .name = param.name,
                    .binding_id = binding_id,
                    .declaration_token = param.name_token,
                    .generic_shape = param_shape,
                    .borrowed_place = try borrowedPlaceDependencyForStoredValue(context, path, program, function.module_name, globals, locals.items, null, param_type, param_provenance),
                    .provenance = param_provenance,
                    .type_id = param_type,
                    .is_param = true,
                    .is_mutable = false,
                    .is_for_binding = false,
                    .is_unavailable = false,
                    .projection_origin = null,
                    .is_scoped_alloc_value = false,
                    .scoped_alloc_origin = null,
                    .scope_depth = context.function_state.block_depth,
                });
                try maybeRecordSemanticHoverFact(context, allocator, path, program, function.module_name, param.name_token, param.name, param_type, param_provenance);
                try params.append(allocator, .{
                    .name = param.name,
                    .type_id = param_type,
                    .binding_id = binding_id,
                });
            }

            phase.end();
            phase = if (context.options.timing_session) |timing_session| timing_session.start("sema.function.body", &.{}) else .{};
            const body = if (function.is_extern)
                try allocator.alloc(sir.Stmt, 0)
            else
                try lowerBlock(context, allocator, path, program, function.module_name, globals, return_type, &locals, function.body);
            if (context.options.timing_session) |timing_session|
                phase.endFunctionBody(timing_session, function.module_name, lowered_owner, lowered_name)
            else
                phase.end();
            phase = if (context.options.timing_session) |timing_session| timing_session.start("sema.function.finish", &.{}) else .{};
            errdefer {
                for (body) |stmt| stmt.deinit(allocator);
                allocator.free(body);
            }

            const function_hover_name = if (lowered_owner) |owner|
                try std.fmt.allocPrint(allocator, "fn {s}.{s}", .{ owner, lowered_name })
            else
                try std.fmt.allocPrint(allocator, "fn {s}", .{lowered_name});
            defer allocator.free(function_hover_name);
            try maybeRecordSemanticHoverFact(context, allocator, path, program, function.module_name, function.name_token, function_hover_name, return_type, .none());

            return .{
                .decl_id = maybeRegisteredDeclId(context, function.module_name, lowered_owner, lowered_name, .function),
                .module_name = function.module_name,
                .owner = lowered_owner,
                .name = lowered_name,
                .abi_name = if (function.is_extern or function.is_export or function.calling_convention == .c)
                    try loweredCAbiSymbolName(context, allocator, function.module_name, function.name, function.abi_name)
                else
                    function.abi_name,
                .is_extern = function.is_extern,
                .is_export = function.is_export,
                .is_isolated = function.is_isolated,
                .syntax_intrinsic_id = intrinsics.resolveSyntaxRole(function.syntax_role),
                .calling_convention = switch (function.calling_convention) {
                    .cyna => .cyna,
                    .c => .c,
                },
                .params = try params.toOwnedSlice(allocator),
                .return_type_id = return_type,
                .debug_token = function.name_token,
                .body = body,
            };
        }

        pub fn lowerAnonymousFunction(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            module_name: []const u8,
            globals: []const GlobalBinding,
            outer_locals: []const LocalBinding,
            function_expr: ast.FunctionExpr,
            function_type_id: semantic_types.TypeId,
            lowered_name: []const u8,
            decl_id: identity.DeclId,
        ) SemaError!LoweredAnonymousFunction {
            const function_type = canonicalTypeNode(context, function_type_id).callable;
            const return_type_id = function_type.return_type;

            const saved_unchecked_depth = context.function_state.unchecked_depth;
            const saved_scoped_alloc_depth = context.function_state.scoped_alloc_depth;
            const saved_scoped_alloc_region_depth = context.function_state.scoped_alloc_region_depth;
            const saved_block_depth = context.function_state.block_depth;
            const saved_loop_depth = context.function_state.loop_depth;
            const saved_switch_yield = context.function_state.active_switch_yield;
            const saved_forbidden_capture_locals = context.function_state.forbidden_capture_locals;
            const saved_forbidden_capture_is_lambda = context.function_state.forbidden_capture_is_lambda;
            const saved_arrow_capture_records = context.function_state.arrow_capture_records;
            const saved_arrow_capture_env_name = context.function_state.arrow_capture_env_name;
            const saved_arrow_capture_env_type_name = context.function_state.arrow_capture_env_type_name;
            const saved_arrow_capture_env_decl_id = context.function_state.arrow_capture_env_decl_id;
            const saved_deferred_return_join = context.function_state.deferred_return_join;
            const saved_active_return_decl_id = context.function_state.active_return_decl_id;
            var captures: std.ArrayListUnmanaged(LocalBinding) = .empty;
            defer captures.deinit(allocator);
            const is_arrow_callable = function_type.kind == .arrow;
            const env_name = generated_names.closure_environment_local;
            const env_type_name = if (is_arrow_callable) blk: {
                const name = try std.fmt.allocPrint(allocator, "{s}{d}", .{ generated_names.closure_environment_type_prefix, context.anonymous_function_counter });
                try context.output.generated_strings.append(allocator, name);
                break :blk name;
            } else null;
            const env_decl_id = if (env_type_name) |name|
                (try registerGeneratedDecl(context, module_name, null, name, .@"struct")) orelse
                    return error.SemanticFailed
            else
                null;
            context.function_state.unchecked_depth = 0;
            context.function_state.scoped_alloc_depth = 0;
            context.function_state.scoped_alloc_region_depth = null;
            context.function_state.block_depth = 0;
            context.function_state.loop_depth = 0;
            context.function_state.active_switch_yield = null;
            context.function_state.active_return_decl_id = decl_id;
            context.function_state.forbidden_capture_locals = outer_locals;
            context.function_state.forbidden_capture_is_lambda = function_expr.is_lambda;
            context.function_state.arrow_capture_records = if (is_arrow_callable) &captures else null;
            context.function_state.arrow_capture_env_name = if (is_arrow_callable) env_name else null;
            context.function_state.arrow_capture_env_type_name = env_type_name;
            context.function_state.arrow_capture_env_decl_id = env_decl_id;
            // A placeholder return type means the concrete result is still a join of
            // binders; collect that join from the lowered returns.
            context.function_state.deferred_return_join = if (canonicalTypeNode(context, return_type_id).* == .generic_parameter and
                canonicalTypeNode(context, return_type_id).generic_parameter.scope == placeholder_generic_scope) &generic_shapes.unknown else null;
            defer {
                context.function_state.unchecked_depth = saved_unchecked_depth;
                context.function_state.scoped_alloc_depth = saved_scoped_alloc_depth;
                context.function_state.scoped_alloc_region_depth = saved_scoped_alloc_region_depth;
                context.function_state.block_depth = saved_block_depth;
                context.function_state.loop_depth = saved_loop_depth;
                context.function_state.active_switch_yield = saved_switch_yield;
                context.function_state.active_return_decl_id = saved_active_return_decl_id;
                context.function_state.forbidden_capture_locals = saved_forbidden_capture_locals;
                context.function_state.forbidden_capture_is_lambda = saved_forbidden_capture_is_lambda;
                context.function_state.arrow_capture_records = saved_arrow_capture_records;
                context.function_state.arrow_capture_env_name = saved_arrow_capture_env_name;
                context.function_state.arrow_capture_env_type_name = saved_arrow_capture_env_type_name;
                context.function_state.arrow_capture_env_decl_id = saved_arrow_capture_env_decl_id;
                if (context.function_state.deferred_return_join) |joined| {
                    recordDeferredShape(context, return_type_id, joined) catch {};
                }
                context.function_state.deferred_return_join = saved_deferred_return_join;
            }

            var locals: std.ArrayListUnmanaged(LocalBinding) = .empty;
            defer locals.deinit(allocator);
            var params: std.ArrayListUnmanaged(sir.Param) = .empty;
            errdefer params.deinit(allocator);

            if (is_arrow_callable) {
                const interner = if (context.canonical.types) |*value| value else return error.SemanticFailed;
                const env_struct_type = try internCanonicalNode(interner, .{ .nominal = .{
                    .kind = .@"struct",
                    .decl_id = env_decl_id.?,
                } });
                const env_param_type = try canonicalRawTypeId(context, env_struct_type, false);
                try appendParamBindingForType(context, allocator, path, program, module_name, globals, &locals, &params, env_name, function_expr.token, env_param_type);
            }

            for (function_expr.params, function_type.params) |param, param_type_id| {
                if (param.type_name) |type_name| {
                    const explicit = try parseCanonicalType(context, path, program, module_name, type_name);
                    if (explicit != param_type_id) {
                        const explicit_display = try formatCanonicalTypeDisplay(context, explicit);
                        defer allocator.free(explicit_display);
                        const expected_display = try formatCanonicalTypeDisplay(context, param_type_id);
                        defer allocator.free(expected_display);
                        try context.diagnostic_context.emitToken(path, param.name_token, "function expression parameter `{s}` has type `{s}`, expected `{s}`", .{
                            param.name,
                            explicit_display,
                            expected_display,
                        });
                        return SemaError.SemanticFailed;
                    }
                }
                try appendParamBindingForType(context, allocator, path, program, module_name, globals, &locals, &params, param.name, param.name_token, param_type_id);
            }

            const body = try lowerBlock(context, allocator, path, program, module_name, globals, return_type_id, &locals, function_expr.body);
            errdefer {
                for (body) |stmt| stmt.deinit(allocator);
                allocator.free(body);
            }
            // The lowered returns are the authority for an open callable result: only a
            // body that still stands for a binder stays open at the definition site.
            if (context.function_state.deferred_return_join) |joined| {
                if (!shapeIsUnsettled(joined)) {
                    try context.diagnostic_context.emitToken(path, function_expr.token, "function expression needs an explicit return type when no expected function type is available", .{});
                    return SemaError.SemanticFailed;
                }
            }
            if (is_arrow_callable) {
                var fields: std.ArrayListUnmanaged(InstantiatedStructField) = .empty;
                errdefer fields.deinit(allocator);
                for (captures.items) |capture| {
                    try fields.append(allocator, .{
                        .name = capture.name,
                        .type_id = if (capture.kind(context) == .ref) canonicalRefTarget(context, capture.type_id) else capture.type_id,
                        .is_pub = false,
                    });
                }
                const type_args = try allocator.alloc(semantic_types.GenericArgument, 0);
                errdefer allocator.free(type_args);
                const owned_fields = try fields.toOwnedSlice(allocator);
                errdefer allocator.free(owned_fields);
                try context.generic.instantiated_structs.append(allocator, .{
                    .id = env_decl_id,
                    .base_decl_id = null,
                    .name = env_type_name.?,
                    .base_name = env_type_name.?,
                    .module_name = module_name,
                    .layout = .normal,
                    .type_args = type_args,
                    .fields = owned_fields,
                });
            }

            const abi_name = if (function_expr.calling_convention == .c)
                try loweredCAbiSymbolName(context, allocator, module_name, lowered_name, null)
            else
                null;

            const owned_params = try params.toOwnedSlice(allocator);
            errdefer allocator.free(owned_params);
            const owned_captures = try allocator.dupe(LocalBinding, captures.items);
            return .{
                .function = .{
                    .module_name = module_name,
                    .owner = null,
                    .name = lowered_name,
                    .abi_name = abi_name,
                    .is_extern = false,
                    .is_export = false,
                    .calling_convention = switch (function_expr.calling_convention) {
                        .cyna => .cyna,
                        .c => .c,
                    },
                    .params = owned_params,
                    .return_type_id = return_type_id,
                    .debug_token = function_expr.token,
                    .body = body,
                },
                .captures = owned_captures,
                .env_type_name = env_type_name,
                .env_decl_id = env_decl_id,
            };
        }

        fn astMentionsLocal(comptime T: type, value: T, name: []const u8) bool {
            if (T == ast.Name) return std.mem.eql(u8, value.text, name);
            if (T == ast.Drop) return std.mem.eql(u8, value.name, name);
            return switch (@typeInfo(T)) {
                .optional => if (value) |item| astMentionsLocal(@TypeOf(item), item, name) else false,
                .pointer => |pointer| blk: {
                    if (pointer.child == u8) break :blk false;
                    if (pointer.size == .one) break :blk astMentionsLocal(pointer.child, value.*, name);
                    if (pointer.size == .slice) {
                        for (value) |item| if (astMentionsLocal(pointer.child, item, name)) return true;
                    }
                    break :blk false;
                },
                .array => |array| blk: {
                    for (value) |item| if (astMentionsLocal(array.child, item, name)) return true;
                    break :blk false;
                },
                .@"struct" => |structure| blk: {
                    inline for (structure.field_names, structure.field_types) |field_name, field_type| {
                        if (astMentionsLocal(field_type, @field(value, field_name), name)) break :blk true;
                    }
                    break :blk false;
                },
                .@"union" => switch (value) {
                    inline else => |payload| astMentionsLocal(@TypeOf(payload), payload, name),
                },
                else => false,
            };
        }

        fn retireUnusedProjectedBindings(locals: []LocalBinding, stmts: []const ast.Stmt, index: usize, depth: usize) void {
            for (locals) |*local| {
                if (local.binding_mode != .projected or local.is_unavailable or local.scope_depth != depth) continue;
                var mentioned = false;
                for (stmts[index..]) |stmt| {
                    if (astMentionsLocal(ast.Stmt, stmt, local.name)) {
                        mentioned = true;
                        break;
                    }
                }
                if (!mentioned) for (stmts[0..index]) |stmt| {
                    if (stmt == .@"defer" and astMentionsLocal(*ast.Expr, stmt.@"defer", local.name)) {
                        mentioned = true;
                        break;
                    }
                };
                if (!mentioned) local.is_unavailable = true;
            }
        }

        pub fn lowerBlock(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            return_type: semantic_types.TypeId,
            locals: *std.ArrayListUnmanaged(LocalBinding),
            stmts: []const ast.Stmt,
        ) SemaError![]const sir.Stmt {
            context.function_state.block_depth += 1;
            defer context.function_state.block_depth -= 1;
            const saved_return_type = context.function_state.current_return_type;
            context.function_state.current_return_type = return_type;
            defer context.function_state.current_return_type = saved_return_type;
            const saved_active_locals = context.function_state.active_locals;
            context.function_state.active_locals = locals;
            defer context.function_state.active_locals = saved_active_locals;
            const snapshot = locals.items.len;
            defer locals.items.len = snapshot;

            var body: std.ArrayListUnmanaged(sir.Stmt) = .empty;
            errdefer {
                for (body.items) |stmt| stmt.deinit(allocator);
                body.deinit(allocator);
            }

            for (stmts, 0..) |stmt, index| {
                retireUnusedProjectedBindings(locals.items, stmts, index, context.function_state.block_depth);
                if (optionalEarlyReturnGuard(context, locals.items, stmt)) |name| {
                    const guard = stmt.@"if";
                    var subject: ast.Expr = .{ .name = name };
                    var condition: ast.Expr = .{ .is_test = .{
                        .subject = &subject,
                        .kind = .optional_some,
                        .case_name = null,
                        .capture_name = name.text,
                        .token = name.token,
                    } };
                    const positive: ast.If = .{
                        .condition = &condition,
                        .then_body = @constCast(stmts[index + 1 ..]),
                        .else_body = guard.then_body,
                    };
                    const lowered = try lowerNarrowIf(context, allocator, path, program, current_module, globals, return_type, locals, positive, true);
                    errdefer lowered.deinit(allocator);
                    try body.append(allocator, lowered);
                    break;
                }
                const lowered = try lowerStmt(context, allocator, path, program, current_module, globals, return_type, locals, stmt);
                errdefer lowered.deinit(allocator);
                try body.append(allocator, lowered);
            }

            for (locals.items[0..snapshot]) |*local| {
                if (local.deferred_handoff_depth == context.function_state.block_depth) {
                    local.is_unavailable = true;
                    local.unavailable_at = local.deferred_handoff_at;
                    local.deferred_handoff_depth = null;
                    local.deferred_handoff_at = null;
                }
            }

            return body.toOwnedSlice(allocator);
        }

        pub fn lowerLoopBodyWithOptionalBinding(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            return_type: semantic_types.TypeId,
            locals: *std.ArrayListUnmanaged(LocalBinding),
            body: []const ast.Stmt,
            snapshot_len: usize,
            binding: ?LocalBinding,
        ) SemaError!LoopBlockChannelsResult {
            const entry_len = locals.items.len;
            if (binding) |value| {
                try locals.append(allocator, value);
            }
            defer locals.items.len = entry_len;
            return try lowerLoopBlockChannels(
                context,
                allocator,
                path,
                program,
                current_module,
                globals,
                return_type,
                locals,
                body,
                snapshot_len,
            );
        }

        pub fn lowerLoopIfChannels(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            return_type: semantic_types.TypeId,
            locals: *std.ArrayListUnmanaged(LocalBinding),
            if_stmt: ast.If,
            snapshot_len: usize,
            allow_same_name_capture: bool,
        ) SemaError!LoopStmtChannels {
            if (if_stmt.condition.* == .name and optionalLocalPayload(context, locals.items, if_stmt.condition.name) != null) {
                const name = if_stmt.condition.name;
                var subject: ast.Expr = .{ .name = name };
                var condition: ast.Expr = .{ .is_test = .{
                    .subject = &subject,
                    .kind = .optional_some,
                    .case_name = null,
                    .capture_name = name.text,
                    .token = name.token,
                } };
                var positive = if_stmt;
                positive.condition = &condition;
                return lowerLoopIfChannels(context, allocator, path, program, current_module, globals, return_type, locals, positive, snapshot_len, true);
            }
            const entry_snapshot = try snapshotLocalState(allocator, locals.items);
            defer allocator.free(entry_snapshot);

            var if_kind: sir.IfKind = .plain;
            var union_decl_id: ?identity.DeclId = null;
            var case_name: ?[]const u8 = null;
            var capture_name: ?[]const u8 = null;
            var capture_type: ?semantic_types.TypeId = null;
            var then_binding: ?LocalBinding = null;
            var condition_expr: ?*sir.Expr = null;
            var condition_type_id: ?semantic_types.TypeId = null;
            var owns_condition_expr = false;
            errdefer if (owns_condition_expr and condition_expr != null) condition_expr.?.destroy(allocator);

            if (if_stmt.condition.* == .is_test) {
                const is_test = if_stmt.condition.is_test;
                const subject = try lowerExpr(context, allocator, path, program, current_module, globals, locals.items, is_test.subject, null);
                condition_expr = subject.expr;
                condition_type_id = subject.type_id;
                owns_condition_expr = true;

                switch (is_test.kind) {
                    .optional_none => {
                        const subject_type_id = if (subject.kind(context) == .ref) canonicalRefTarget(context, subject.type_id) else subject.type_id;
                        if (canonicalTypeNode(context, subject_type_id).* != .optional) {
                            try context.diagnostic_context.emitToken(path, is_test.token, "`is none` requires an optional value", .{});
                            return SemaError.SemanticFailed;
                        }
                        if_kind = .optional_none;
                    },
                    .optional_some => {
                        const subject_type_id = if (subject.kind(context) == .ref) canonicalRefTarget(context, subject.type_id) else subject.type_id;
                        const optional_payload_id = switch (canonicalTypeNode(context, subject_type_id).*) {
                            .optional => |payload| payload,
                            else => {
                                try context.diagnostic_context.emitToken(path, is_test.token, "`is name` requires an optional value", .{});
                                return SemaError.SemanticFailed;
                            },
                        };
                        if_kind = .optional_some;
                        capture_type = optional_payload_id;
                    },
                    .union_case => {
                        const resolved = try resolveTagNarrowCase(context, path, program, current_module, subject, is_test);
                        if_kind = .union_case;
                        union_decl_id = resolved.union_decl_id;
                        case_name = resolved.case_name;
                        capture_type = resolved.capture_type;
                    },
                }

                if (is_test.capture_name) |name| {
                    if (!allow_same_name_capture and findLocal(locals.items, name) != null) {
                        try context.diagnostic_context.emitToken(path, is_test.token, "duplicate local `{s}`", .{name});
                        return SemaError.SemanticFailed;
                    }
                    var binding = try localBinding(context, name, capture_type.?, false, false);
                    if (is_test.kind == .optional_some) binding.generic_shape = try loweredProjectionShape(context, subject.generic_shape, capture_type, .payload);
                    binding.generic_origin = try payloadOrigin(context, capture_type, subject);
                    binding.provenance = try switchPayloadCaptureProvenance(context, path, program, current_module, globals, locals.items, is_test.subject, capture_type.?, subject.provenance.derived());
                    binding.borrowed_place = try borrowedPlaceDependencyForStoredValue(context, path, program, current_module, globals, locals.items, is_test.subject, capture_type.?, binding.provenance);
                    binding.projection_origin = is_test.subject;
                    if (is_test.capture_token) |capture_token| {
                        try maybeRecordSemanticHoverFact(context, allocator, path, program, current_module, capture_token, name, binding.type_id, binding.provenance);
                    }
                    capture_name = name;
                    then_binding = binding;
                }
            } else {
                const condition = try lowerExpr(context, allocator, path, program, current_module, globals, locals.items, if_stmt.condition, try canonicalPrimitiveTypeId(context, .bool));
                errdefer condition.expr.destroy(allocator);
                try expectType(context, path, firstExprToken(if_stmt.condition), try canonicalPrimitiveTypeId(context, .bool), condition.type_id);
                condition_expr = condition.expr;
                condition_type_id = condition.type_id;
                owns_condition_expr = true;
            }

            const then_result = try lowerLoopBodyWithOptionalBinding(
                context,
                allocator,
                path,
                program,
                current_module,
                globals,
                return_type,
                locals,
                if_stmt.then_body,
                snapshot_len,
                then_binding,
            );
            errdefer {
                for (then_result.body) |stmt| stmt.deinit(allocator);
                allocator.free(then_result.body);
                if (then_result.fallthrough_state) |state| allocator.free(state);
                if (then_result.continue_state) |state| allocator.free(state);
                if (then_result.break_state) |state| allocator.free(state);
            }

            restoreLocalState(locals.items, entry_snapshot);
            const else_result = try lowerLoopBodyWithOptionalBinding(
                context,
                allocator,
                path,
                program,
                current_module,
                globals,
                return_type,
                locals,
                if_stmt.else_body,
                snapshot_len,
                null,
            );
            errdefer {
                for (else_result.body) |stmt| stmt.deinit(allocator);
                allocator.free(else_result.body);
                if (else_result.fallthrough_state) |state| allocator.free(state);
                if (else_result.continue_state) |state| allocator.free(state);
                if (else_result.break_state) |state| allocator.free(state);
            }

            var fallthrough_state: ?[]LocalBinding = null;
            errdefer if (fallthrough_state) |state| allocator.free(state);
            if (then_result.fallthrough_state) |state| try mergeOptionalLocalState(context, allocator, &fallthrough_state, state);
            if (else_result.fallthrough_state) |state| try mergeOptionalLocalState(context, allocator, &fallthrough_state, state);

            var continue_state: ?[]LocalBinding = null;
            var break_state: ?[]LocalBinding = null;
            errdefer if (continue_state) |state| allocator.free(state);
            errdefer if (break_state) |state| allocator.free(state);
            if (then_result.continue_state) |state| try mergeOptionalLocalState(context, allocator, &continue_state, state);
            if (then_result.break_state) |state| try mergeOptionalLocalState(context, allocator, &break_state, state);
            if (else_result.continue_state) |state| try mergeOptionalLocalState(context, allocator, &continue_state, state);
            if (else_result.break_state) |state| try mergeOptionalLocalState(context, allocator, &break_state, state);

            if (fallthrough_state) |state| {
                restoreLocalState(locals.items[0..snapshot_len], state);
            } else {
                restoreLocalState(locals.items, entry_snapshot);
            }

            if (then_result.fallthrough_state) |state| allocator.free(state);
            if (then_result.continue_state) |state| allocator.free(state);
            if (then_result.break_state) |state| allocator.free(state);
            if (else_result.fallthrough_state) |state| allocator.free(state);
            if (else_result.continue_state) |state| allocator.free(state);
            if (else_result.break_state) |state| allocator.free(state);
            owns_condition_expr = false;

            return .{
                .stmt = .{ .@"if" = .{
                    .kind = if_kind,
                    .condition = condition_expr.?,
                    .union_decl_id = union_decl_id,
                    .case_name = case_name,
                    .capture_name = capture_name,
                    .capture_binding_id = if (then_binding) |binding| binding.binding_id else null,
                    .capture_type_id = capture_type,
                    .capture_path = if (capture_name != null) checkedCapturePath(checkedCaptureOrigin(context, condition_expr.?), checkedIfPayloadCase(context, program, if_kind, condition_type_id, union_decl_id, case_name)) else null,
                    .then_body = then_result.body,
                    .else_body = else_result.body,
                } },
                .fallthrough_state = fallthrough_state,
                .continue_state = continue_state,
                .break_state = break_state,
            };
        }

        pub fn lowerLoopSwitchBranchChannels(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            return_type: semantic_types.TypeId,
            locals: *std.ArrayListUnmanaged(LocalBinding),
            body: []const ast.Stmt,
            snapshot_len: usize,
            payload_name: ?[]const u8,
            payload_type: ?semantic_types.TypeId,
            payload_provenance: Provenance,
            subject_expr: ?*ast.Expr,
            payload_shape: *const generic_shapes.Shape,
            subject_origin: ?GenericReceiverOrigin,
        ) SemaError!struct { body: []const sir.Stmt, fallthrough_state: ?[]LocalBinding, continue_state: ?[]LocalBinding, break_state: ?[]LocalBinding, payload_binding_id: ?identity.BindingId } {
            var binding: ?LocalBinding = null;
            if (payload_name) |name| {
                if (findLocal(locals.items, name) != null) {
                    try context.diagnostic_context.emitToken(path, firstExprToken(subject_expr.?), "duplicate local `{s}`", .{name});
                    return SemaError.SemanticFailed;
                }
                var local = try localBinding(context, name, payload_type orelse unreachable, false, false);
                local.generic_shape = payload_shape;
                local.generic_origin = subject_origin;
                local.provenance = try switchPayloadCaptureProvenance(context, path, program, current_module, globals, locals.items, subject_expr, payload_type orelse unreachable, payload_provenance);
                local.borrowed_place = try borrowedPlaceDependencyForStoredValue(context, path, program, current_module, globals, locals.items, subject_expr, payload_type orelse unreachable, local.provenance);
                local.projection_origin = subject_expr;
                binding = local;
            }
            const lowered = try lowerLoopBodyWithOptionalBinding(
                context,
                allocator,
                path,
                program,
                current_module,
                globals,
                return_type,
                locals,
                body,
                snapshot_len,
                binding,
            );
            return .{ .body = lowered.body, .fallthrough_state = lowered.fallthrough_state, .continue_state = lowered.continue_state, .break_state = lowered.break_state, .payload_binding_id = if (binding) |value| value.binding_id else null };
        }

        pub fn deferDefinitionSiteSwitchCases(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            return_type: semantic_types.TypeId,
            locals: *std.ArrayListUnmanaged(LocalBinding),
            switch_stmt: ast.Switch,
            value: *const TypedExpr,
            snapshot_len: usize,
        ) SemaError!LoopStmtChannels {
            const payload_shape = try context.generic.shapes.project(allocator, value.generic_shape);
            var body: std.ArrayListUnmanaged(sir.Stmt) = .empty;
            errdefer {
                for (body.items) |stmt| stmt.deinit(allocator);
                body.deinit(allocator);
            }
            var branch_count = switch_stmt.cases.len;
            if (switch_stmt.has_else) branch_count += 1;
            var branches = try allocator.alloc([]const ast.Stmt, branch_count);
            defer allocator.free(branches);
            for (switch_stmt.cases, 0..) |case, index| branches[index] = case.body;
            if (switch_stmt.has_else) branches[switch_stmt.cases.len] = switch_stmt.else_body;
            for (branches, 0..) |branch, index| {
                const payload_name = if (index < switch_stmt.cases.len) switch_stmt.cases[index].payload_name else null;
                const lowered = try lowerLoopSwitchBranchChannels(
                    context,
                    allocator,
                    path,
                    program,
                    current_module,
                    globals,
                    return_type,
                    locals,
                    branch,
                    snapshot_len,
                    payload_name,
                    value.type_id,
                    value.provenance.derived(),
                    null,
                    payload_shape,
                    projectedOrigin(value.generic_origin),
                );
                errdefer {
                    for (lowered.body) |stmt| stmt.deinit(allocator);
                    allocator.free(lowered.body);
                    if (lowered.fallthrough_state) |state| allocator.free(state);
                    if (lowered.continue_state) |state| allocator.free(state);
                    if (lowered.break_state) |state| allocator.free(state);
                }
                try body.appendSlice(allocator, lowered.body);
                allocator.free(lowered.body);
                if (lowered.fallthrough_state) |state| allocator.free(state);
                if (lowered.continue_state) |state| allocator.free(state);
                if (lowered.break_state) |state| allocator.free(state);
            }
            value.expr.destroy(allocator);
            return .{
                .stmt = .{ .unchecked = try body.toOwnedSlice(allocator) },
                .fallthrough_state = null,
                .continue_state = null,
                .break_state = null,
            };
        }

        pub fn lowerLoopSwitchChannels(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            return_type: semantic_types.TypeId,
            locals: *std.ArrayListUnmanaged(LocalBinding),
            switch_stmt: ast.Switch,
            snapshot_len: usize,
        ) SemaError!LoopStmtChannels {
            const value = try lowerExpr(context, allocator, path, program, current_module, globals, locals.items, switch_stmt.value, null);
            errdefer value.expr.destroy(allocator);
            var statement_target: @TypeOf(context.function_state).SwitchYieldContext = .{ .parent = context.function_state.active_switch_yield };
            context.function_state.active_switch_yield = &statement_target;
            defer context.function_state.active_switch_yield = statement_target.parent;
            const entry_snapshot = try snapshotLocalState(allocator, locals.items);
            defer allocator.free(entry_snapshot);
            if (isDefinitionSiteBinder(context, try value.canonicalTypeId(context))) {
                return deferDefinitionSiteSwitchCases(context, allocator, path, program, current_module, globals, return_type, locals, switch_stmt, &value, snapshot_len);
            }

            var cases: std.ArrayListUnmanaged(sir.SwitchCase) = .empty;
            errdefer {
                for (cases.items) |case| {
                    for (case.body) |stmt| stmt.deinit(allocator);
                    allocator.free(case.body);
                    if (case.scalar_pattern) |pattern| switch (pattern) {
                        .string => |text| allocator.free(text),
                        .int => {},
                    };
                }
                cases.deinit(allocator);
            }

            var fallthrough_state: ?[]LocalBinding = null;
            errdefer if (fallthrough_state) |state| allocator.free(state);
            var continue_state: ?[]LocalBinding = null;
            var break_state: ?[]LocalBinding = null;
            errdefer if (continue_state) |state| allocator.free(state);
            errdefer if (break_state) |state| allocator.free(state);

            var subject_type: sir.Type = undefined;
            var subject_decl_id: ?identity.DeclId = null;
            var subject_type_name: []const u8 = undefined;

            if (value.kind(context) == .int or value.kind(context) == .string) {
                const is_integer = value.kind(context) == .int;
                if (!switch_stmt.has_else) {
                    try context.diagnostic_context.emitToken(path, firstExprToken(switch_stmt.value), "integer and string switches require a final `_` arm", .{});
                    return SemaError.SemanticFailed;
                }
                try cases.ensureTotalCapacity(allocator, switch_stmt.cases.len);
                for (switch_stmt.cases) |case| {
                    var scalar: sir.SwitchCase = .{ .case_name = "", .payload_name = null, .body = &.{} };
                    var owns_scalar_pattern = true;
                    errdefer if (owns_scalar_pattern) if (scalar.scalar_pattern) |pattern| switch (pattern) {
                        .string => |text| allocator.free(text),
                        .int => {},
                    };
                    if (is_integer) {
                        const pattern_value = if (case.scalar_pattern) |pattern|
                            constantIntegerAst(globals, current_module, locals.items, pattern, 0)
                        else blk: {
                            if (case.type_name != null or case.payload_name != null or case.type_variant == null) break :blk null;
                            var name_expr: ast.Expr = .{ .name = .{ .text = case.case_name, .token = case.token } };
                            break :blk constantIntegerAst(globals, current_module, locals.items, &name_expr, 0);
                        };
                        const integer = pattern_value orelse {
                            try context.diagnostic_context.emitToken(path, case.token, "integer switch pattern must be a compile-time integer constant", .{});
                            return SemaError.SemanticFailed;
                        };
                        const type_name = try canonicalIntegerLiteralTypeName(context, value.type_id) orelse "i64";
                        if (integer < std.math.minInt(i64) or integer > std.math.maxInt(u64) or
                            !intLiteralFitsType(context, if (integer > std.math.maxInt(i64)) 0 else @intCast(integer), if (integer > std.math.maxInt(i64)) @intCast(integer) else null, type_name))
                        {
                            try context.diagnostic_context.emitToken(path, case.token, "integer switch pattern does not fit subject type `{s}`", .{type_name});
                            return SemaError.SemanticFailed;
                        }
                        const bits: u64 = if (integer < 0) @bitCast(@as(i64, @intCast(integer))) else @intCast(integer);
                        scalar.scalar_pattern = .{ .int = @bitCast(bits) };
                        for (cases.items) |prior| if (prior.scalar_pattern) |seen| switch (seen) {
                            .int => |number| if (number == scalar.scalar_pattern.?.int) {
                                try context.diagnostic_context.emitToken(path, case.token, "duplicate integer switch pattern", .{});
                                return SemaError.SemanticFailed;
                            },
                            .string => {},
                        };
                    } else {
                        const pattern = case.scalar_pattern orelse {
                            try context.diagnostic_context.emitToken(path, case.token, "string switch pattern must be a string literal", .{});
                            return SemaError.SemanticFailed;
                        };
                        if (pattern.* != .string) {
                            try context.diagnostic_context.emitToken(path, case.token, "string switch pattern must be a string literal", .{});
                            return SemaError.SemanticFailed;
                        }
                        const pattern_text = pattern.string.text;
                        for (cases.items) |prior| if (prior.scalar_pattern) |seen| switch (seen) {
                            .string => |other| if (std.mem.eql(u8, pattern_text, other)) {
                                try context.diagnostic_context.emitToken(path, case.token, "duplicate string switch pattern", .{});
                                return SemaError.SemanticFailed;
                            },
                            .int => {},
                        };
                        const copied = try allocator.dupe(u8, pattern_text);
                        scalar.scalar_pattern = .{ .string = copied };
                    }
                    const lowered = try lowerLoopSwitchBranchChannels(context, allocator, path, program, current_module, globals, return_type, locals, case.body, snapshot_len, null, null, .none(), null, &generic_shapes.unknown, null);
                    errdefer {
                        for (lowered.body) |stmt| stmt.deinit(allocator);
                        allocator.free(lowered.body);
                        if (lowered.fallthrough_state) |state| allocator.free(state);
                        if (lowered.continue_state) |state| allocator.free(state);
                        if (lowered.break_state) |state| allocator.free(state);
                    }
                    if (lowered.fallthrough_state) |state| try mergeOptionalLocalState(context, allocator, &fallthrough_state, state);
                    if (lowered.continue_state) |state| try mergeOptionalLocalState(context, allocator, &continue_state, state);
                    if (lowered.break_state) |state| try mergeOptionalLocalState(context, allocator, &break_state, state);
                    scalar.body = lowered.body;
                    try cases.append(allocator, scalar);
                    owns_scalar_pattern = false;
                    if (lowered.fallthrough_state) |state| allocator.free(state);
                    if (lowered.continue_state) |state| allocator.free(state);
                    if (lowered.break_state) |state| allocator.free(state);
                    restoreLocalState(locals.items, entry_snapshot);
                }
                const lowered_else = try lowerLoopSwitchBranchChannels(context, allocator, path, program, current_module, globals, return_type, locals, switch_stmt.else_body, snapshot_len, null, null, .none(), null, &generic_shapes.unknown, null);
                defer if (lowered_else.fallthrough_state) |state| allocator.free(state);
                defer if (lowered_else.continue_state) |state| allocator.free(state);
                defer if (lowered_else.break_state) |state| allocator.free(state);
                errdefer {
                    for (lowered_else.body) |stmt| stmt.deinit(allocator);
                    allocator.free(lowered_else.body);
                }
                if (lowered_else.fallthrough_state) |state| try mergeOptionalLocalState(context, allocator, &fallthrough_state, state);
                if (lowered_else.continue_state) |state| try mergeOptionalLocalState(context, allocator, &continue_state, state);
                if (lowered_else.break_state) |state| try mergeOptionalLocalState(context, allocator, &break_state, state);
                if (fallthrough_state) |state| restoreLocalState(locals.items[0..snapshot_len], state) else restoreLocalState(locals.items, entry_snapshot);
                return .{
                    .stmt = .{ .@"switch" = .{
                        .value = value.expr,
                        .subject_type_id = try value.canonicalTypeId(context),
                        .subject_type_name = if (is_integer) "integer" else "string",
                        .cases = try cases.toOwnedSlice(allocator),
                        .has_else = true,
                        .else_body = lowered_else.body,
                    } },
                    .fallthrough_state = fallthrough_state,
                    .continue_state = continue_state,
                    .break_state = break_state,
                };
            }

            if (value.kind(context) == .@"enum") {
                const enum_decl_id = canonicalNominalDeclId(context, value.type_id) orelse return error.SemanticFailed;
                const enum_decl = lookupEnumDeclById(context, program, enum_decl_id) orelse return error.SemanticFailed;
                const enum_name = enum_decl.name;
                subject_type = .@"enum";
                subject_decl_id = enum_decl_id;
                subject_type_name = enum_name;

                for (switch_stmt.cases) |case| {
                    if (case.type_name) |case_type_name| {
                        if (!std.mem.eql(u8, case_type_name, enum_name)) {
                            try context.diagnostic_context.emitToken(path, case.token, "switch case type `{s}` does not match `{s}`", .{ case_type_name, enum_name });
                            return SemaError.SemanticFailed;
                        }
                    }
                    if (case.payload_name != null) {
                        try context.diagnostic_context.emitToken(path, case.token, "enum switch cases cannot bind payloads", .{});
                        return SemaError.SemanticFailed;
                    }
                    if (findEnumCase(enum_decl.cases, case.case_name) == null) {
                        try context.diagnostic_context.emitToken(path, case.token, "enum `{s}` has no case `{s}`", .{ enum_name, case.case_name });
                        return SemaError.SemanticFailed;
                    }
                    const lowered = try lowerLoopSwitchBranchChannels(context, allocator, path, program, current_module, globals, return_type, locals, case.body, snapshot_len, null, null, .none(), null, &generic_shapes.unknown, null);
                    errdefer {
                        for (lowered.body) |stmt| stmt.deinit(allocator);
                        allocator.free(lowered.body);
                        if (lowered.fallthrough_state) |state| allocator.free(state);
                        if (lowered.continue_state) |state| allocator.free(state);
                        if (lowered.break_state) |state| allocator.free(state);
                    }
                    if (lowered.fallthrough_state) |state| try mergeOptionalLocalState(context, allocator, &fallthrough_state, state);
                    if (lowered.continue_state) |state| try mergeOptionalLocalState(context, allocator, &continue_state, state);
                    if (lowered.break_state) |state| try mergeOptionalLocalState(context, allocator, &break_state, state);
                    try cases.append(allocator, .{
                        .case_name = case.case_name,
                        .payload_name = null,
                        .body = lowered.body,
                    });
                    if (lowered.fallthrough_state) |state| allocator.free(state);
                    if (lowered.continue_state) |state| allocator.free(state);
                    if (lowered.break_state) |state| allocator.free(state);
                    restoreLocalState(locals.items, entry_snapshot);
                }

                const lowered_else = try lowerLoopSwitchBranchChannels(context, allocator, path, program, current_module, globals, return_type, locals, switch_stmt.else_body, snapshot_len, null, null, .none(), null, &generic_shapes.unknown, null);
                defer if (lowered_else.fallthrough_state) |state| allocator.free(state);
                defer if (lowered_else.continue_state) |state| allocator.free(state);
                defer if (lowered_else.break_state) |state| allocator.free(state);
                errdefer {
                    for (lowered_else.body) |stmt| stmt.deinit(allocator);
                    allocator.free(lowered_else.body);
                }
                if (enum_decl.layout == .c and !switch_stmt.has_else) {
                    try context.diagnostic_context.emitToken(path, firstExprToken(switch_stmt.value), "switch over `c enum` `{s}` requires `else`", .{enum_name});
                    return SemaError.SemanticFailed;
                }
                if (lowered_else.fallthrough_state) |state| try mergeOptionalLocalState(context, allocator, &fallthrough_state, state);
                if (lowered_else.continue_state) |state| try mergeOptionalLocalState(context, allocator, &continue_state, state);
                if (lowered_else.break_state) |state| try mergeOptionalLocalState(context, allocator, &break_state, state);
                const else_body = lowered_else.body;

                if (!switch_stmt.has_else) {
                    for (enum_decl.cases) |enum_case| {
                        if (!switchCoversCase(switch_stmt.cases, enum_name, enum_case.name)) {
                            try context.diagnostic_context.emitToken(path, firstExprToken(switch_stmt.value), "non-exhaustive switch on `{s}`; missing `{s}.{s}`", .{ enum_name, enum_name, enum_case.name });
                            return SemaError.SemanticFailed;
                        }
                    }
                }

                if (fallthrough_state) |state| restoreLocalState(locals.items[0..snapshot_len], state) else restoreLocalState(locals.items, entry_snapshot);
                return .{
                    .stmt = .{ .@"switch" = .{
                        .value = value.expr,
                        .subject_type_id = try value.canonicalTypeId(context),
                        .subject_decl_id = subject_decl_id,
                        .subject_type_name = subject_type_name,
                        .cases = try cases.toOwnedSlice(allocator),
                        .has_else = switch_stmt.has_else,
                        .else_body = else_body,
                    } },
                    .fallthrough_state = fallthrough_state,
                    .continue_state = continue_state,
                    .break_state = break_state,
                };
            }

            if (value.kind(context) == .@"union" or value.kind(context) == .result) {
                const is_result = value.kind(context) == .result;
                if (is_result and !switch_stmt.catch_fallback) {
                    try context.diagnostic_context.emitToken(moduleSourcePath(program, current_module, path), firstExprToken(switch_stmt.value), "switch on an error return is unavailable; use `catch (code) {{ ... }}`", .{});
                    return SemaError.SemanticFailed;
                }
                const result = if (is_result) canonicalTypeNode(context, value.type_id).result else undefined;
                const inline_members: ?[]const semantic_types.TypeId = if (!is_result) switch (canonicalTypeNode(context, value.type_id).*) {
                    .error_union => |members| members,
                    else => null,
                } else null;
                const error_decl_id = if (is_result) canonicalNominalDeclId(context, result.err) else null;
                const union_decl_id = if (!is_result) canonicalNominalDeclId(context, value.type_id) else null;
                const union_decl = if (!is_result and inline_members == null) lookupUnionDeclById(context, program, union_decl_id orelse return error.SemanticFailed) orelse return error.SemanticFailed else null;
                const error_name = if (is_result) blk: {
                    if (canonicalTypeNode(context, result.err).* == .error_union) break :blk "__inline_error_union";
                    const decl_id = error_decl_id orelse return error.SemanticFailed;
                    if (lookupEnumDeclById(context, program, decl_id)) |decl| break :blk decl.name;
                    if (lookupUnionDeclById(context, program, decl_id)) |decl| break :blk decl.name;
                    return error.SemanticFailed;
                } else null;
                const union_name = if (is_result) error_name.? else if (union_decl) |decl| decl.name else "__inline_error_union";
                subject_type = if (is_result) .result else .@"union";
                subject_decl_id = if (is_result) error_decl_id else union_decl_id;
                subject_type_name = union_name;
                var saw_ok = false;
                var saw_err = false;
                const ok_type = if (is_result) result.ok else undefined;
                const err_type = if (is_result) result.err else undefined;

                for (switch_stmt.cases) |case| {
                    var payload_name: ?[]const u8 = null;
                    var payload_type: ?semantic_types.TypeId = null;
                    var resolved_case_name = case.case_name;
                    var result_case: ?sir.ResultCase = null;
                    var union_ordinal: ?u32 = null;
                    if (is_result) {
                        if (case.type_name != null or case.type_variant != null) {
                            try context.diagnostic_context.emitToken(path, case.token, "switch on result requires `.ok` or `.err` case labels", .{});
                            return SemaError.SemanticFailed;
                        }
                        result_case = language_contracts.resolveResultCase(case.case_name) orelse {
                            try context.diagnostic_context.emitToken(path, case.token, "result has no case `.{s}`", .{case.case_name});
                            return SemaError.SemanticFailed;
                        };
                        switch (result_case.?) {
                            .ok => {
                                saw_ok = true;
                                payload_name = case.payload_name;
                                if (case.payload_name != null and canonicalTypeKind(context, ok_type) == .void) {
                                    try context.diagnostic_context.emitToken(path, case.token, "result case `.ok` does not carry a payload for result<void, E>", .{});
                                    return SemaError.SemanticFailed;
                                }
                                payload_type = if (case.payload_name != null and canonicalTypeKind(context, ok_type) != .void) ok_type else null;
                            },
                            .err => {
                                saw_err = true;
                                payload_name = case.payload_name;
                                payload_type = if (case.payload_name != null) err_type else null;
                            },
                        }
                    } else {
                        const resolved = if (inline_members) |members|
                            try resolveInlineErrorUnionSwitchCase(context, allocator, path, program, current_module, members, case)
                        else
                            try resolveUnionSwitchCase(context, allocator, path, program, current_module, union_name, union_decl.?, case);
                        resolved_case_name = resolved.case_name;
                        payload_name = resolved.payload_name;
                        payload_type = resolved.payload_type_id;
                        union_ordinal = resolved.ordinal;
                    }

                    const payload_shape = try loweredCasePayloadShape(context, value.generic_shape, payload_type);
                    const lowered = try lowerLoopSwitchBranchChannels(context, allocator, path, program, current_module, globals, return_type, locals, case.body, snapshot_len, payload_name, payload_type, value.provenance.derived(), switch_stmt.value, payload_shape, try payloadOrigin(context, payload_type, value));
                    errdefer {
                        for (lowered.body) |stmt| stmt.deinit(allocator);
                        allocator.free(lowered.body);
                        if (lowered.fallthrough_state) |state| allocator.free(state);
                        if (lowered.continue_state) |state| allocator.free(state);
                        if (lowered.break_state) |state| allocator.free(state);
                    }
                    if (lowered.fallthrough_state) |state| try mergeOptionalLocalState(context, allocator, &fallthrough_state, state);
                    if (lowered.continue_state) |state| try mergeOptionalLocalState(context, allocator, &continue_state, state);
                    if (lowered.break_state) |state| try mergeOptionalLocalState(context, allocator, &break_state, state);
                    try cases.append(allocator, .{
                        .case_name = resolved_case_name,
                        .union_ordinal = if (inline_members != null) union_ordinal else null,
                        .result_case = result_case,
                        .payload_name = payload_name,
                        .payload_binding_id = lowered.payload_binding_id,
                        .payload_type_id = if (payload_name != null) payload_type else null,
                        .payload_path = if (payload_name == null) null else checkedCapturePath(checkedCaptureOrigin(context, value.expr), if (result_case) |kind|
                            .{ .result = kind }
                        else if (inline_members != null)
                            .{ .inline_error_union = .{ .type_id = value.type_id, .ordinal = union_ordinal.? } }
                        else
                            .{ .union_field = .{ .owner_decl_id = union_decl_id.?, .ordinal = union_ordinal.? } }),
                        .body = lowered.body,
                    });
                    if (lowered.fallthrough_state) |state| allocator.free(state);
                    if (lowered.continue_state) |state| allocator.free(state);
                    if (lowered.break_state) |state| allocator.free(state);
                    restoreLocalState(locals.items, entry_snapshot);
                }

                const lowered_else = try lowerLoopSwitchBranchChannels(context, allocator, path, program, current_module, globals, return_type, locals, switch_stmt.else_body, snapshot_len, null, null, .none(), null, &generic_shapes.unknown, null);
                defer if (lowered_else.fallthrough_state) |state| allocator.free(state);
                defer if (lowered_else.continue_state) |state| allocator.free(state);
                defer if (lowered_else.break_state) |state| allocator.free(state);
                errdefer {
                    for (lowered_else.body) |stmt| stmt.deinit(allocator);
                    allocator.free(lowered_else.body);
                }
                if (lowered_else.fallthrough_state) |state| try mergeOptionalLocalState(context, allocator, &fallthrough_state, state);
                if (lowered_else.continue_state) |state| try mergeOptionalLocalState(context, allocator, &continue_state, state);
                if (lowered_else.break_state) |state| try mergeOptionalLocalState(context, allocator, &break_state, state);
                const else_body = lowered_else.body;

                if (!switch_stmt.has_else) {
                    if (is_result) {
                        if (!saw_ok or !saw_err) {
                            try context.diagnostic_context.emitToken(path, firstExprToken(switch_stmt.value), "non-exhaustive switch on result; missing `.ok` or `.err`", .{});
                            return SemaError.SemanticFailed;
                        }
                    } else {
                        if (inline_members) |members| {
                            for (members) |member| {
                                var covered = false;
                                for (switch_stmt.cases) |case| {
                                    if (case.type_variant) |variant| {
                                        if (try parseType(context, path, program, current_module, variant) == member) covered = true;
                                    }
                                }
                                if (!covered) {
                                    try context.diagnostic_context.emitToken(path, firstExprToken(switch_stmt.value), "non-exhaustive switch on inline error union", .{});
                                    return SemaError.SemanticFailed;
                                }
                            }
                        } else switch (union_decl.?.kind) {
                            .named_cases => for (union_decl.?.fields) |field| {
                                if (!switchCoversCase(switch_stmt.cases, null, field.name)) {
                                    try context.diagnostic_context.emitToken(path, firstExprToken(switch_stmt.value), "non-exhaustive switch on `{s}`; missing `.{s}`", .{ union_name, field.name });
                                    return SemaError.SemanticFailed;
                                }
                            },
                            .type_union => for (union_decl.?.variants) |variant| {
                                if (!(try switchCoversTypeUnionVariant(context, path, program, current_module, switch_stmt.cases, union_decl.?, variant))) {
                                    const variant_type = try parseType(context, path, program, union_decl.?.module_name, variant);
                                    const display = try formatTypeDisplay(context, variant_type);
                                    defer allocator.free(display);
                                    try context.diagnostic_context.emitToken(path, firstExprToken(switch_stmt.value), "non-exhaustive switch on `{s}`; missing `{s}`", .{ union_name, display });
                                    return SemaError.SemanticFailed;
                                }
                            },
                        }
                    }
                }

                if (fallthrough_state) |state| restoreLocalState(locals.items[0..snapshot_len], state) else restoreLocalState(locals.items, entry_snapshot);
                return .{
                    .stmt = .{ .@"switch" = .{
                        .value = value.expr,
                        .subject_type_id = try value.canonicalTypeId(context),
                        .subject_decl_id = subject_decl_id,
                        .subject_type_name = subject_type_name,
                        .cases = try cases.toOwnedSlice(allocator),
                        .has_else = switch_stmt.has_else,
                        .else_body = else_body,
                    } },
                    .fallthrough_state = fallthrough_state,
                    .continue_state = continue_state,
                    .break_state = break_state,
                };
            }

            try context.diagnostic_context.emitToken(path, firstExprToken(switch_stmt.value), "switch requires an enum or union value", .{});
            return SemaError.SemanticFailed;
        }

        pub fn lowerLoopUncheckedChannels(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            return_type: semantic_types.TypeId,
            locals: *std.ArrayListUnmanaged(LocalBinding),
            body: []const ast.Stmt,
            snapshot_len: usize,
        ) SemaError!LoopStmtChannels {
            context.function_state.unchecked_depth += 1;
            defer context.function_state.unchecked_depth -= 1;

            const lowered = try lowerLoopBlockChannels(context, allocator, path, program, current_module, globals, return_type, locals, body, snapshot_len);
            errdefer {
                for (lowered.body) |stmt| stmt.deinit(allocator);
                allocator.free(lowered.body);
                if (lowered.fallthrough_state) |state| allocator.free(state);
                if (lowered.continue_state) |state| allocator.free(state);
                if (lowered.break_state) |state| allocator.free(state);
            }

            return .{
                .stmt = .{ .unchecked = lowered.body },
                .fallthrough_state = lowered.fallthrough_state,
                .continue_state = lowered.continue_state,
                .break_state = lowered.break_state,
            };
        }

        pub fn lowerLoopUsingAllocChannels(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            return_type: semantic_types.TypeId,
            locals: *std.ArrayListUnmanaged(LocalBinding),
            using_alloc: ast.UsingAlloc,
            snapshot_len: usize,
        ) SemaError!LoopStmtChannels {
            const allocator_expr = try lowerExpr(context, allocator, path, program, current_module, globals, locals.items, using_alloc.allocator_expr, null);
            errdefer allocator_expr.expr.destroy(allocator);

            const lowered = if (using_alloc.is_scoped) blk: {
                const prev_region_depth = context.function_state.scoped_alloc_region_depth;
                context.function_state.scoped_alloc_region_depth = context.function_state.block_depth + 1;
                defer context.function_state.scoped_alloc_region_depth = prev_region_depth;
                context.function_state.scoped_alloc_depth += 1;
                defer context.function_state.scoped_alloc_depth -= 1;
                break :blk try lowerLoopBlockChannels(context, allocator, path, program, current_module, globals, return_type, locals, using_alloc.body, snapshot_len);
            } else try lowerLoopBlockChannels(context, allocator, path, program, current_module, globals, return_type, locals, using_alloc.body, snapshot_len);
            errdefer {
                for (lowered.body) |stmt| stmt.deinit(allocator);
                allocator.free(lowered.body);
                if (lowered.fallthrough_state) |state| allocator.free(state);
                if (lowered.continue_state) |state| allocator.free(state);
                if (lowered.break_state) |state| allocator.free(state);
            }

            return .{
                .stmt = .{ .using_alloc = .{
                    .is_scoped = using_alloc.is_scoped,
                    .allocator_expr = allocator_expr.expr,
                    .body = lowered.body,
                } },
                .fallthrough_state = lowered.fallthrough_state,
                .continue_state = lowered.continue_state,
                .break_state = lowered.break_state,
            };
        }

        pub fn lowerLoopBlockChannels(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            return_type: semantic_types.TypeId,
            locals: *std.ArrayListUnmanaged(LocalBinding),
            body: []const ast.Stmt,
            snapshot_len: usize,
        ) SemaError!LoopBlockChannelsResult {
            const entry_len = locals.items.len;
            defer locals.items.len = entry_len;
            var lowered: std.ArrayListUnmanaged(sir.Stmt) = .empty;
            errdefer {
                for (lowered.items) |stmt| stmt.deinit(allocator);
                lowered.deinit(allocator);
            }

            var continue_state: ?[]LocalBinding = null;
            var break_state: ?[]LocalBinding = null;
            errdefer if (continue_state) |state| allocator.free(state);
            errdefer if (break_state) |state| allocator.free(state);
            var flow_active = true;

            for (body, 0..) |stmt, index| {
                if (!flow_active) break;
                if (optionalEarlyReturnGuard(context, locals.items, stmt)) |name| {
                    const guard = stmt.@"if";
                    var subject: ast.Expr = .{ .name = name };
                    var condition: ast.Expr = .{ .is_test = .{
                        .subject = &subject,
                        .kind = .optional_some,
                        .case_name = null,
                        .capture_name = name.text,
                        .token = name.token,
                    } };
                    const positive: ast.If = .{
                        .condition = &condition,
                        .then_body = @constCast(body[index + 1 ..]),
                        .else_body = guard.then_body,
                    };
                    const lowered_stmt = try lowerLoopIfChannels(context, allocator, path, program, current_module, globals, return_type, locals, positive, snapshot_len, true);
                    defer if (lowered_stmt.continue_state) |state| allocator.free(state);
                    defer if (lowered_stmt.break_state) |state| allocator.free(state);
                    defer if (lowered_stmt.fallthrough_state) |state| allocator.free(state);
                    try appendOwnedLowered(allocator, &lowered, lowered_stmt.stmt);
                    if (lowered_stmt.continue_state) |state| try mergeOptionalLocalState(context, allocator, &continue_state, state);
                    if (lowered_stmt.break_state) |state| try mergeOptionalLocalState(context, allocator, &break_state, state);
                    if (lowered_stmt.fallthrough_state) |state| {
                        restoreLocalState(locals.items[0..snapshot_len], state);
                    } else {
                        flow_active = false;
                    }
                    break;
                }
                switch (stmt) {
                    .unchecked => {
                        const lowered_stmt = try lowerLoopUncheckedChannels(context, allocator, path, program, current_module, globals, return_type, locals, stmt.unchecked, snapshot_len);
                        defer if (lowered_stmt.continue_state) |state| allocator.free(state);
                        defer if (lowered_stmt.break_state) |state| allocator.free(state);
                        defer if (lowered_stmt.fallthrough_state) |state| allocator.free(state);
                        try appendOwnedLowered(allocator, &lowered, lowered_stmt.stmt);
                        if (lowered_stmt.continue_state) |state| {
                            try mergeOptionalLocalState(context, allocator, &continue_state, state);
                        }
                        if (lowered_stmt.break_state) |state| {
                            try mergeOptionalLocalState(context, allocator, &break_state, state);
                        }
                        if (lowered_stmt.fallthrough_state) |state| {
                            restoreLocalState(locals.items[0..snapshot_len], state);
                        } else {
                            flow_active = false;
                        }
                    },
                    .using_alloc => {
                        const lowered_stmt = try lowerLoopUsingAllocChannels(context, allocator, path, program, current_module, globals, return_type, locals, stmt.using_alloc, snapshot_len);
                        defer if (lowered_stmt.continue_state) |state| allocator.free(state);
                        defer if (lowered_stmt.break_state) |state| allocator.free(state);
                        defer if (lowered_stmt.fallthrough_state) |state| allocator.free(state);
                        try appendOwnedLowered(allocator, &lowered, lowered_stmt.stmt);
                        if (lowered_stmt.continue_state) |state| {
                            try mergeOptionalLocalState(context, allocator, &continue_state, state);
                        }
                        if (lowered_stmt.break_state) |state| {
                            try mergeOptionalLocalState(context, allocator, &break_state, state);
                        }
                        if (lowered_stmt.fallthrough_state) |state| {
                            restoreLocalState(locals.items[0..snapshot_len], state);
                        } else {
                            flow_active = false;
                        }
                    },
                    .@"if" => {
                        const lowered_stmt = try lowerLoopIfChannels(context, allocator, path, program, current_module, globals, return_type, locals, stmt.@"if", snapshot_len, false);
                        defer if (lowered_stmt.continue_state) |state| allocator.free(state);
                        defer if (lowered_stmt.break_state) |state| allocator.free(state);
                        defer if (lowered_stmt.fallthrough_state) |state| allocator.free(state);
                        try appendOwnedLowered(allocator, &lowered, lowered_stmt.stmt);
                        if (lowered_stmt.continue_state) |state| {
                            try mergeOptionalLocalState(context, allocator, &continue_state, state);
                        }
                        if (lowered_stmt.break_state) |state| {
                            try mergeOptionalLocalState(context, allocator, &break_state, state);
                        }
                        if (lowered_stmt.fallthrough_state) |state| {
                            restoreLocalState(locals.items[0..snapshot_len], state);
                        } else {
                            flow_active = false;
                        }
                    },
                    .@"switch" => {
                        const lowered_stmt = try lowerLoopSwitchChannels(context, allocator, path, program, current_module, globals, return_type, locals, stmt.@"switch", snapshot_len);
                        defer if (lowered_stmt.continue_state) |state| allocator.free(state);
                        defer if (lowered_stmt.break_state) |state| allocator.free(state);
                        defer if (lowered_stmt.fallthrough_state) |state| allocator.free(state);
                        try appendOwnedLowered(allocator, &lowered, lowered_stmt.stmt);
                        if (lowered_stmt.continue_state) |state| {
                            try mergeOptionalLocalState(context, allocator, &continue_state, state);
                        }
                        if (lowered_stmt.break_state) |state| {
                            try mergeOptionalLocalState(context, allocator, &break_state, state);
                        }
                        if (lowered_stmt.fallthrough_state) |state| {
                            restoreLocalState(locals.items[0..snapshot_len], state);
                        } else {
                            flow_active = false;
                        }
                    },
                    .@"return" => {
                        const lowered_stmt = try lowerStmt(context, allocator, path, program, current_module, globals, return_type, locals, stmt);
                        try appendOwnedLowered(allocator, &lowered, lowered_stmt);
                        flow_active = false;
                    },
                    .@"continue" => {
                        const lowered_stmt = try lowerStmt(context, allocator, path, program, current_module, globals, return_type, locals, stmt);
                        try appendOwnedLowered(allocator, &lowered, lowered_stmt);
                        try mergeOptionalLocalState(context, allocator, &continue_state, locals.items[0..snapshot_len]);
                        flow_active = false;
                    },
                    .@"break" => {
                        const lowered_stmt = try lowerStmt(context, allocator, path, program, current_module, globals, return_type, locals, stmt);
                        try appendOwnedLowered(allocator, &lowered, lowered_stmt);
                        try mergeOptionalLocalState(context, allocator, &break_state, locals.items[0..snapshot_len]);
                        flow_active = false;
                    },
                    else => {
                        const lowered_stmt = try lowerStmt(context, allocator, path, program, current_module, globals, return_type, locals, stmt);
                        try appendOwnedLowered(allocator, &lowered, lowered_stmt);
                    },
                }
            }

            const fallthrough_state = if (flow_active)
                try snapshotLocalState(allocator, locals.items[0..snapshot_len])
            else
                null;
            errdefer if (fallthrough_state) |state| allocator.free(state);

            return .{
                .body = try lowered.toOwnedSlice(allocator),
                .fallthrough_state = fallthrough_state,
                .continue_state = continue_state,
                .break_state = break_state,
            };
        }

        pub fn lowerJoinedIfBodies(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            return_type: semantic_types.TypeId,
            locals: *std.ArrayListUnmanaged(LocalBinding),
            then_body: []const ast.Stmt,
            else_body: []const ast.Stmt,
            capture: ?LocalBinding,
        ) SemaError!struct { then_body: []const sir.Stmt, else_body: []const sir.Stmt } {
            const entry_snapshot = try snapshotLocalState(allocator, locals.items);
            defer allocator.free(entry_snapshot);
            defer locals.items.len = entry_snapshot.len;

            if (capture) |binding| try locals.append(allocator, binding);

            const lowered_then = try lowerBlock(context, allocator, path, program, current_module, globals, return_type, locals, then_body);
            errdefer {
                for (lowered_then) |stmt| stmt.deinit(allocator);
                allocator.free(lowered_then);
            }
            const then_snapshot = try snapshotLocalState(allocator, locals.items[0..entry_snapshot.len]);
            defer allocator.free(then_snapshot);
            const then_falls_through = !sirBlockDefinitelyTerminates(lowered_then);

            restoreLocalState(locals.items[0..entry_snapshot.len], entry_snapshot);
            locals.items.len = entry_snapshot.len;
            const lowered_else = try lowerBlock(context, allocator, path, program, current_module, globals, return_type, locals, else_body);
            errdefer {
                for (lowered_else) |stmt| stmt.deinit(allocator);
                allocator.free(lowered_else);
            }
            const else_snapshot = try snapshotLocalState(allocator, locals.items);
            defer allocator.free(else_snapshot);
            const else_falls_through = !sirBlockDefinitelyTerminates(lowered_else);

            if (then_falls_through and else_falls_through) {
                try mergeJoinedLocalState(context, locals.items, then_snapshot, else_snapshot);
            } else if (then_falls_through) {
                restoreLocalState(locals.items, then_snapshot);
            } else if (else_falls_through) {
                restoreLocalState(locals.items, else_snapshot);
            } else {
                restoreLocalState(locals.items, entry_snapshot);
            }
            return .{
                .then_body = lowered_then,
                .else_body = lowered_else,
            };
        }

        pub fn lowerFixedPointLoopBody(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            return_type: semantic_types.TypeId,
            locals: *std.ArrayListUnmanaged(LocalBinding),
            body: []const ast.Stmt,
            loop_head_len: usize,
            carried_len: usize,
        ) SemaError!struct { body: []const sir.Stmt, state: []LocalBinding } {
            const entry_snapshot = try snapshotLocalState(allocator, locals.items[0..loop_head_len]);
            defer allocator.free(entry_snapshot);
            var loop_head_state = try snapshotLocalState(allocator, locals.items[0..loop_head_len]);
            defer allocator.free(loop_head_state);

            var final_body: ?[]const sir.Stmt = null;
            errdefer if (final_body) |body_stmts| {
                for (body_stmts) |stmt| stmt.deinit(allocator);
                allocator.free(body_stmts);
            };
            var final_state: ?[]LocalBinding = null;
            errdefer if (final_state) |state| allocator.free(state);

            while (true) {
                restoreLocalState(locals.items[0..loop_head_len], loop_head_state);
                const lowered_loop = try lowerLoopBlockChannels(
                    context,
                    allocator,
                    path,
                    program,
                    current_module,
                    globals,
                    return_type,
                    locals,
                    body,
                    loop_head_len,
                );
                defer if (lowered_loop.break_state) |state| allocator.free(state);
                // Each iteration releases its own channels; whichever of them survives
                // into `final_body`/`final_state` stops being owned by this scope.
                var loop_body_owned = true;
                var fallthrough_owned = true;
                var continue_state_owned = true;
                errdefer {
                    if (loop_body_owned) {
                        for (lowered_loop.body) |stmt| stmt.deinit(allocator);
                        allocator.free(lowered_loop.body);
                    }
                    if (fallthrough_owned) {
                        if (lowered_loop.fallthrough_state) |state| allocator.free(state);
                    }
                    if (continue_state_owned) {
                        if (lowered_loop.continue_state) |state| allocator.free(state);
                    }
                }

                const next_carried = try snapshotLocalState(allocator, loop_head_state[0..carried_len]);
                errdefer allocator.free(next_carried);
                if (lowered_loop.fallthrough_state) |state| {
                    try mergeJoinedLocalStateInPlace(context, next_carried, state[0..carried_len]);
                }
                if (lowered_loop.continue_state) |state| {
                    try mergeJoinedLocalStateInPlace(context, next_carried, state[0..carried_len]);
                }

                if (final_body) |previous| {
                    for (previous) |stmt| stmt.deinit(allocator);
                    allocator.free(previous);
                }
                final_body = lowered_loop.body;
                loop_body_owned = false;
                if (final_state) |previous_state| {
                    allocator.free(previous_state);
                    final_state = null;
                }
                if (lowered_loop.fallthrough_state) |state| {
                    // The carried state moves out of this iteration's ownership.
                    final_state = state;
                    fallthrough_owned = false;
                } else if (lowered_loop.continue_state) |state| {
                    final_state = try snapshotLocalState(allocator, state);
                    allocator.free(state);
                    continue_state_owned = false;
                } else {
                    final_state = try snapshotLocalState(allocator, loop_head_state);
                }
                if (lowered_loop.continue_state) |state| {
                    // A continue state that did not become the carried state is still
                    // owned by this iteration once its facts have been merged.
                    if (continue_state_owned) {
                        allocator.free(state);
                        continue_state_owned = false;
                    }
                }

                // Breaks contribute to the exit, never to the next iteration.
                if (lowered_loop.break_state) |state| {
                    try mergeJoinedLocalStateInPlace(context, final_state.?, state);
                }

                if (localAbstractStateEql(loop_head_state[0..carried_len], next_carried)) {
                    restoreLocalState(locals.items[0..loop_head_len], entry_snapshot);
                    try mergeJoinedLocalStateInPlace(context, locals.items[0..carried_len], next_carried);
                    if (lowered_loop.break_state) |state| {
                        try mergeJoinedLocalStateInPlace(context, locals.items[0..carried_len], state[0..carried_len]);
                    }
                    allocator.free(next_carried);
                    break;
                }

                restoreLocalState(loop_head_state[0..loop_head_len], entry_snapshot);
                try mergeJoinedLocalStateInPlace(context, loop_head_state[0..carried_len], next_carried);
                allocator.free(next_carried);
            }

            return .{
                .body = final_body orelse try allocator.alloc(sir.Stmt, 0),
                .state = final_state orelse try allocator.alloc(LocalBinding, 0),
            };
        }

        pub fn lowerSwitchBranchBody(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            return_type: semantic_types.TypeId,
            locals: *std.ArrayListUnmanaged(LocalBinding),
            branch_body: []const ast.Stmt,
            payload_name: ?[]const u8,
            payload_type: ?semantic_types.TypeId,
            payload_provenance: Provenance,
            subject_expr: ?*ast.Expr,
            payload_shape: *const generic_shapes.Shape,
            subject_origin: ?GenericReceiverOrigin,
            entry_len: usize,
        ) SemaError!struct { body: []const sir.Stmt, state: []LocalBinding, payload_binding_id: ?identity.BindingId } {
            std.debug.assert(locals.items.len == entry_len);
            var added_payload_binding = false;
            defer {
                if (added_payload_binding) locals.items.len = entry_len;
            }
            var payload_binding_id: ?identity.BindingId = null;
            if (payload_name) |name| {
                var binding = try localBinding(context, name, payload_type orelse unreachable, false, false);
                payload_binding_id = binding.binding_id;
                binding.generic_shape = payload_shape;
                binding.generic_origin = subject_origin;
                binding.provenance = try switchPayloadCaptureProvenance(context, path, program, current_module, globals, locals.items, subject_expr, payload_type orelse unreachable, payload_provenance);
                binding.borrowed_place = try borrowedPlaceDependencyForStoredValue(context, path, program, current_module, globals, locals.items, subject_expr, payload_type orelse unreachable, binding.provenance);
                binding.projection_origin = subject_expr;
                try locals.append(allocator, binding);
                added_payload_binding = true;
            }

            const body = try lowerBlock(context, allocator, path, program, current_module, globals, return_type, locals, branch_body);
            errdefer {
                for (body) |stmt| stmt.deinit(allocator);
                allocator.free(body);
            }
            const state = try snapshotLocalState(allocator, locals.items[0..entry_len]);
            errdefer allocator.free(state);
            return .{
                .body = body,
                .state = state,
                .payload_binding_id = payload_binding_id,
            };
        }

        pub fn lowerJoinedSwitchBody(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            return_type: semantic_types.TypeId,
            locals: *std.ArrayListUnmanaged(LocalBinding),
            branch_body: []const ast.Stmt,
            payload_name: ?[]const u8,
            payload_type: ?semantic_types.TypeId,
            payload_provenance: Provenance,
            subject_expr: ?*ast.Expr,
            payload_shape: *const generic_shapes.Shape,
            subject_origin: ?GenericReceiverOrigin,
            entry_snapshot: []const LocalBinding,
            merged_state: ?[]LocalBinding,
        ) SemaError!struct { body: []const sir.Stmt, state: []LocalBinding, merged: []LocalBinding, payload_binding_id: ?identity.BindingId } {
            restoreLocalState(locals.items, entry_snapshot);
            const lowered = try lowerSwitchBranchBody(
                context,
                allocator,
                path,
                program,
                current_module,
                globals,
                return_type,
                locals,
                branch_body,
                payload_name,
                payload_type,
                payload_provenance,
                subject_expr,
                payload_shape,
                subject_origin,
                entry_snapshot.len,
            );
            errdefer {
                for (lowered.body) |stmt| stmt.deinit(allocator);
                allocator.free(lowered.body);
            }
            errdefer allocator.free(lowered.state);
            const branch_falls_through = !sirBlockDefinitelyTerminates(lowered.body);
            const merged = if (branch_falls_through)
                if (merged_state) |acc| blk: {
                    try mergeJoinedLocalStateInPlace(context, acc, lowered.state);
                    break :blk acc;
                } else blk: {
                    const snapshot = try snapshotLocalState(allocator, lowered.state);
                    errdefer allocator.free(snapshot);
                    break :blk snapshot;
                }
            else
                merged_state orelse blk: {
                    const snapshot = try snapshotLocalState(allocator, entry_snapshot);
                    errdefer allocator.free(snapshot);
                    break :blk snapshot;
                };
            return .{
                .body = lowered.body,
                .state = lowered.state,
                .merged = merged,
                .payload_binding_id = lowered.payload_binding_id,
            };
        }

        /// A checked place reached through a local can introduce an
        /// owner-linked binding without transferring the projected value.
        fn projectedBindingPlace(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            locals: []const LocalBinding,
            source: *ast.Expr,
            value_type: semantic_types.TypeId,
            metadata: sir.ExprMetadata,
        ) SemaError!?sir.CheckedPlacePath {
            if (!try canonicalTypeIsOwnedValue(context, path, program, value_type)) return null;
            const source_is_direct = switch (source.*) {
                .name => true,
                .field => |field| field.object.* == .name,
                .index => |index| index.object.* == .name,
                else => return null,
            };
            const source_local: LocalBinding = switch (source.*) {
                .name => |name| blk: {
                    const local = findLocal(locals, name.text) orelse return null;
                    if (local.binding_mode != .projected) return null;
                    break :blk local;
                },
                .field => |field| projectedSourceRootLocal(locals, field.object) orelse return null,
                .index => |index| projectedSourceRootLocal(locals, index.object) orelse return null,
                else => return null,
            };
            if (source_local.is_unavailable) return null;
            const place = metadata.checkedPlacePath() orelse return null;
            if (place.root != .binding or place.projections == null or place.projections.?.len == 0) return null;
            var crosses_union_payload = false;
            for (place.projections.?) |projection| switch (projection.step) {
                .union_payload => crosses_union_payload = true,
                .field, .index => {},
                else => return null,
            };
            if (!source_is_direct and !crosses_union_payload) return null;
            const owner = blk: {
                for (locals) |candidate| {
                    if (candidate.binding_id == place.root.binding) break :blk candidate;
                }
                return null;
            };
            if (owner.binding_mode != .owning or owner.is_unavailable or
                owner.scope_depth > context.function_state.block_depth) return null;
            if (owner.kind(context) != .@"struct" and
                owner.kind(context) != .@"union" and
                owner.kind(context) != .array and owner.kind(context) != .dense_array and
                owner.kind(context) != .slice and owner.kind(context) != .ref) return null;
            if ((owner.kind(context) == .slice or owner.kind(context) == .ref) and
                !owner.borrowed_place.hasBorrow()) return null;
            if (source_local.binding_mode == .owning and source_local.binding_id != owner.binding_id) return null;
            if (!try projectedPathIsStable(context, path, program, owner.type_id, place.projections.?)) return null;
            return .{ .root = place.root, .projections = place.projections, .non_owning = true };
        }

        fn projectedSourceRootLocal(locals: []const LocalBinding, source: *ast.Expr) ?LocalBinding {
            return switch (source.*) {
                .name => |name| findLocal(locals, name.text),
                .field => |field| projectedSourceRootLocal(locals, field.object),
                .index => |index| projectedSourceRootLocal(locals, index.object),
                else => null,
            };
        }

        fn projectedPathIsStable(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            root_type: semantic_types.TypeId,
            projections: []const sir.CheckedPlaceProjection,
        ) SemaError!bool {
            var current_type = canonicalUnwrapOwned(context, root_type);
            for (projections) |projection| {
                var node = canonicalTypeNode(context, current_type);
                while (node.* == .ref_) {
                    current_type = node.ref_.target;
                    node = canonicalTypeNode(context, current_type);
                }
                switch (projection.step) {
                    .field => |field| {
                        if (canonicalTypeKind(context, current_type) != .@"struct") return false;
                        const decl_id = canonicalNominalDeclId(context, current_type) orelse return false;
                        if (decl_id != field.owner_decl_id) return false;
                        const decl = lookupStructDeclById(context, program, decl_id) orelse return false;
                        if (decl.layout != .normal) return false;
                        const decl_field = lookupStructField(decl, field.name) orelse return false;
                        const field_type = try structFieldTypeId(context, path, program, decl, decl_field);
                        if (field_type != projection.result_type_id) return false;
                        current_type = field_type;
                    },
                    .union_payload => |field| {
                        if (canonicalTypeKind(context, current_type) != .@"union") return false;
                        const decl_id = canonicalNominalDeclId(context, current_type) orelse return false;
                        if (decl_id != field.owner_decl_id) return false;
                        const decl = lookupUnionDeclById(context, program, decl_id) orelse return false;
                        if (decl.layout != .normal or decl.kind != .named_cases) return false;
                        const union_field = findUnionField(decl.fields, field.name) orelse return false;
                        const type_name = union_field.type_name orelse return false;
                        const payload_type = try parseCanonicalType(context, path, program, decl.module_name, type_name);
                        if (payload_type != projection.result_type_id) return false;
                        current_type = payload_type;
                    },
                    .index => |index| {
                        current_type = switch (node.*) {
                            .array => |array| array.item,
                            .dense_array => |item| item,
                            .slice => |slice| slice.item,
                            .tuple => |members| blk: {
                                const position = switch (index) {
                                    .fixed => |value| std.math.cast(usize, value) orelse return false,
                                    .dynamic => return false,
                                };
                                if (position >= members.len) return false;
                                break :blk members[position];
                            },
                            else => return false,
                        };
                        if (current_type != projection.result_type_id) return false;
                    },
                    .range => return false,
                }
            }
            return true;
        }

        fn projectedBorrowDependency(context: *SemaContext, locals: []const LocalBinding, place: sir.CheckedPlacePath) ownership_owner.BorrowedPlaceDependency {
            const owner = blk: {
                for (locals) |candidate| {
                    if (candidate.binding_id == place.root.binding) break :blk candidate;
                }
                unreachable;
            };
            const via_alias = owner.kind(context) == .slice or owner.kind(context) == .ref;
            var projection = if (via_alias) owner.borrowed_place.projection else ownership_owner.PlaceProjectionPath.root();
            for (place.projections.?) |step| switch (step.step) {
                .field => |field| projection.appendField(field.name),
                .union_payload => |field| projection.appendField(field.name),
                .index => |index| projection.appendIndex(if (index == .fixed) index.fixed else null),
                else => unreachable,
            };
            var roots = if (via_alias)
                owner.borrowed_place.roots
            else if (owner.is_param)
                ownership_owner.NormalizedBorrowRoots.paramOwnerValue(owner.name)
            else
                ownership_owner.NormalizedBorrowRoots.localValue(owner.name);
            // A slice borrowed through a parameter carries the pointee's
            // param root. Place mutations through that parameter use its
            // owner root; retain both identities for invalidation checks.
            if (roots.contains_param) {
                if (roots.precise_param_roots) {
                    for (roots.param_roots[0..roots.param_root_count]) |name| {
                        if (name) |param_name| roots = ownership_owner.NormalizedBorrowRoots.combine(roots, ownership_owner.NormalizedBorrowRoots.paramOwnerValue(param_name));
                    }
                } else {
                    roots.contains_param_owner = true;
                    roots.precise_param_owner_roots = false;
                    roots.param_owner_root_count = 0;
                }
            }
            return .{
                .roots = roots,
                .projection = projection,
                .mode = .alias,
            };
        }

        fn projectedRootLocal(locals: []const LocalBinding, source: *ast.Expr) ?LocalBinding {
            return switch (source.*) {
                .name => |name| blk: {
                    const local = findLocal(locals, name.text) orelse break :blk null;
                    break :blk if (local.binding_mode == .projected) local else null;
                },
                .field => |field| projectedRootLocal(locals, field.object),
                .index => |index| projectedRootLocal(locals, index.object),
                else => null,
            };
        }

        fn isResourceFromRawInitializer(expr: *ast.Expr) bool {
            return expr.* == .method_call and
                expr.method_call.object.* == .name and
                std.mem.eql(u8, expr.method_call.object.name.text, "resource") and
                std.mem.eql(u8, expr.method_call.method, "from_raw");
        }

        pub fn lowerStmt(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            return_type: semantic_types.TypeId,
            locals: *std.ArrayListUnmanaged(LocalBinding),
            stmt: ast.Stmt,
        ) SemaError!sir.Stmt {
            switch (stmt) {
                .discard => |expr| {
                    const value = try lowerExpr(context, allocator, path, program, current_module, globals, locals.items, expr, null);
                    errdefer value.expr.destroy(allocator);
                    try rejectProjectedResourceTransferForTypedValue(context, path, program, firstExprToken(expr), value, value.type_id, "discard");
                    try lowerImplicitHandoff(context, path, program, locals.items, expr, value.type_id, value.expr);
                    try markCheckedNamedHandoff(context, path, program, locals.items, expr, value.expr, value.type_id);
                    return .{ .expr = value.expr };
                },
                .local => |local| {
                    if (findLocal(locals.items, local.name)) |existing| {
                        var labels: [1]diagnostics.Label = undefined;
                        const label_slice: []const diagnostics.Label = if (existing.declaration_token) |decl_token| blk: {
                            labels[0] = .{
                                .span = diagnostics.SourceSpan.fromToken(path, decl_token),
                                .message = "first local declared here",
                            };
                            break :blk &labels;
                        } else &.{};
                        const notes = [_][]const u8{"local names must be unique within the active lexical scopes"};
                        try context.diagnostic_context.emitTokenWith(path, local.name_token, .{
                            .code = .duplicate_declaration,
                            .labels = label_slice,
                            .notes = &notes,
                            .help = "rename this binding or use a different nested scope",
                        }, "duplicate local `{s}`", .{local.name});
                        return SemaError.SemanticFailed;
                    }

                    const local_type_id = if (local.type_name) |type_name|
                        try parseCanonicalType(context, path, program, current_module, type_name)
                    else
                        null;
                    const local_type = local_type_id;
                    if (local_type) |ty| {
                        try rejectArrowCallableStorageType(context, path, local.name_token, ty, "local binding");
                    }
                    const saved_expectation_origin = context.function_state.expected_type_origin;
                    context.function_state.expected_type_origin = if (local.type_name) |type_name| .{
                        .path = path,
                        .token = type_name.token,
                        .message = "binding type annotation declared here",
                    } else null;
                    defer context.function_state.expected_type_origin = saved_expectation_origin;
                    const saved_resource_from_raw_initializer = context.function_state.resource_from_raw_initializer;
                    context.function_state.resource_from_raw_initializer = isResourceFromRawInitializer(local.init);
                    defer context.function_state.resource_from_raw_initializer = saved_resource_from_raw_initializer;
                    const init = try lowerExprInContext(context, allocator, path, program, current_module, globals, locals.items, local.init, local_type_id);
                    errdefer init.expr.destroy(allocator);
                    const final_local_type_id = local_type_id orelse init.type_id;
                    try rejectArrowCallableStorageType(context, path, local.name_token, final_local_type_id, "local binding");
                    if (canonicalTypeIsVoidLike(context, final_local_type_id)) {
                        try context.diagnostic_context.emitToken(path, local.name_token, "a `void` value cannot be stored in a local binding", .{});
                        return SemaError.SemanticFailed;
                    }
                    try expectTypeFrom(context, path, local.name_token, final_local_type_id, init.type_id, if (local.type_name) |type_name| .{
                        .path = path,
                        .token = type_name.token,
                        .message = "binding type annotation declared here",
                    } else null);
                    if (try typeMayCarryBorrowedProvenance(context, path, program, current_module, final_local_type_id)) {
                        if (init.provenance.hasBorrow() and !provenanceOutlivesScope(locals.items, init.provenance, context.function_state.block_depth)) {
                            try emitOwnershipDiagnostic(
                                context,
                                path,
                                local.name_token,
                                .ownership_borrow_escape,
                                firstExprToken(local.init),
                                "borrowed value originates here",
                                "the binding outlives the borrowed source",
                                "store an owned value or shorten the binding lifetime",
                                "borrowed values cannot escape into longer-lived bindings",
                                .{},
                            );
                            return SemaError.SemanticFailed;
                        }
                    }
                    const source_metadata = semanticExprMetadata(context, init.expr) orelse return error.SemanticFailed;
                    const projected_place = if (!local.is_mutable)
                        try projectedBindingPlace(context, path, program, locals.items, local.init, final_local_type_id, source_metadata)
                    else
                        null;
                    if (projected_place) |place| {
                        try rejectProjectedBindingWritableAliasConflict(context, path, locals.items, projectedBorrowDependency(context, locals.items, place), local.name_token);
                    }
                    if (projected_place == null) {
                        try rejectProjectedResourceTransferForTypedValue(context, path, program, local.name_token, init, final_local_type_id, "binding");
                        try lowerImplicitHandoff(context, path, program, locals.items, local.init, final_local_type_id, init.expr);
                    }
                    try recordExprSink(context, init.expr, .initialize);
                    if (projected_place == null)
                        try markCheckedNamedHandoff(context, path, program, locals.items, local.init, init.expr, final_local_type_id);
                    const local_shape = if (local.type_name != null) try shapeFromCanonicalType(context, final_local_type_id, false) else init.generic_shape;
                    // An explicit annotation names the binder the binding stands for, so
                    // a use of the binding is admitted against that binder's own
                    // constraints even when the initializer projected the value out of
                    // another binder.
                    const declared_origin = if (local.type_name != null) receiverOriginFromType(context, final_local_type_id) else null;
                    const binding_id = try nextBindingId(context);
                    try locals.append(allocator, .{
                        .name = local.name,
                        .constant_int_value = if (!local.is_mutable and canonicalTypeKind(context, final_local_type_id) == .int)
                            constantIntegerAst(globals, current_module, locals.items, local.init, 0)
                        else
                            null,
                        .binding_id = binding_id,
                        .binding_mode = if (projected_place != null) .projected else .owning,
                        .projected_place = projected_place,
                        .declaration_token = local.name_token,
                        .generic_shape = local_shape,
                        .generic_origin = declared_origin orelse init.generic_origin,
                        .borrowed_place = if (projected_place) |place| projectedBorrowDependency(context, locals.items, place) else try checkedStoredBorrowDependency(context, path, program, current_module, globals, locals.items, local.init, init.expr, final_local_type_id, init.provenance),
                        .provenance = if (projected_place) |place| ownership_owner.Provenance.fromNormalizedBorrowRoots(projectedBorrowDependency(context, locals.items, place).roots) else init.provenance,
                        .type_id = final_local_type_id,
                        .is_param = false,
                        .is_mutable = local.is_mutable,
                        .is_for_binding = false,
                        .is_unavailable = false,
                        .projection_origin = local.init,
                        .is_scoped_alloc_value = context.function_state.scoped_alloc_depth > 0 and try typeMayCaptureAllocator(context, path, program, final_local_type_id) and exprCarriesScopedAlloc(locals.items, local.init),
                        .scoped_alloc_origin = if (context.function_state.scoped_alloc_depth > 0 and !local.is_mutable and exprCarriesScopedAlloc(locals.items, local.init)) local.init else null,
                        .scope_depth = context.function_state.block_depth,
                    });
                    try maybeRecordSemanticHoverFact(context, allocator, path, program, current_module, local.name_token, local.name, final_local_type_id, if (projected_place) |place| ownership_owner.Provenance.fromNormalizedBorrowRoots(projectedBorrowDependency(context, locals.items, place).roots) else init.provenance);

                    const init_metadata = semanticExprMetadata(context, init.expr) orelse return error.SemanticFailed;
                    const checked_effect: ?sir.Record = if (projected_place == null and init_metadata.consumption.transfer == .move and
                        (init_metadata.semantics.ownership == .owned or init_metadata.semantics.ownership == .shared))
                    blk: {
                        const temporary = init_metadata.temporary_id orelse return error.SemanticFailed;
                        const record: sir.Record = .{ .effect = .{ .move = .{
                            .source = .{ .temporary = temporary },
                            .destination = .{ .place = .{
                                .root = .{ .binding = binding_id },
                                .projections = null,
                                .non_owning = false,
                            } },
                        } } };
                        record.validate() catch return error.SemanticFailed;
                        break :blk record;
                    } else null;

                    return .{ .local = .{
                        .name = local.name,
                        .type_id = final_local_type_id,
                        .binding_id = binding_id,
                        .binding_mode = if (projected_place != null) .projected else .owning,
                        .projected_place = projected_place,
                        .init = init.expr,
                        .checked_effect = checked_effect,
                    } };
                },
                .unchecked => |unchecked_body| {
                    context.function_state.unchecked_depth += 1;
                    defer context.function_state.unchecked_depth -= 1;
                    return .{ .unchecked = try lowerBlock(context, allocator, path, program, current_module, globals, return_type, locals, unchecked_body) };
                },
                .asm_stmt => |asm_stmt| {
                    const used_inputs = try allocator.alloc(bool, asm_stmt.inputs.len);
                    defer allocator.free(used_inputs);
                    @memset(used_inputs, false);
                    try validateAsmPlaceholders(context, path, asm_stmt, used_inputs);

                    var lowered_inputs = try allocator.alloc(sir.AsmInput, asm_stmt.inputs.len);
                    var lowered_input_count: usize = 0;
                    errdefer {
                        for (lowered_inputs[0..lowered_input_count]) |input| input.deinit(allocator);
                        allocator.free(lowered_inputs);
                    }

                    for (asm_stmt.inputs, 0..) |input, i| {
                        const lowered = try lowerExpr(context, allocator, path, program, current_module, globals, locals.items, input.value, null);
                        errdefer lowered.expr.destroy(allocator);
                        try expectAsmInputType(context, path, input.name_token, try lowered.canonicalTypeId(context));
                        lowered_inputs[i] = .{
                            .name = input.name,
                            .constraint = lowerAsmConstraint(input.constraint),
                            .value = lowered.expr,
                        };
                        lowered_input_count += 1;
                    }

                    const lines = try allocator.alloc([]const u8, asm_stmt.lines.len);
                    errdefer allocator.free(lines);
                    @memcpy(lines, asm_stmt.lines);
                    const clobbers = try allocator.alloc(sir.AsmClobber, asm_stmt.clobbers.len);
                    var clobber_count: usize = 0;
                    errdefer {
                        for (clobbers[0..clobber_count]) |clobber| clobber.deinit(allocator);
                        allocator.free(clobbers);
                    }
                    for (asm_stmt.clobbers, 0..) |clobber, i| {
                        clobbers[i] = try lowerAsmClobber(context, allocator, path, asm_stmt.token, clobber);
                        clobber_count = i + 1;
                    }
                    return .{ .asm_stmt = .{
                        .lines = lines,
                        .inputs = lowered_inputs,
                        .clobbers = clobbers,
                        .is_volatile = asm_stmt.is_volatile,
                    } };
                },
                .assign => |assign| {
                    const target_local = findLocal(locals.items, assign.name);
                    const target_type = blk: {
                        if (target_local) |binding| {
                            if (binding.is_failure_view) {
                                try context.diagnostic_context.emitToken(path, assign.name_token, "cannot assign to a failure view", .{});
                                return SemaError.SemanticFailed;
                            }
                            if (binding.is_unavailable) {
                                try emitUnavailableLocal(context, path, assign.name_token, binding, false);
                                return SemaError.SemanticFailed;
                            }
                            if (binding.kind(context) == .ref and canonicalRefIsConst(context, binding.type_id)) {
                                try context.diagnostic_context.emitToken(path, assign.name_token, "cannot assign through read-only alias `{s}`", .{assign.name});
                                return SemaError.SemanticFailed;
                            }
                            if (binding.kind(context) != .ref and !binding.is_mutable) {
                                try context.diagnostic_context.emitToken(path, assign.name_token, "cannot assign to const local `{s}`", .{assign.name});
                                return SemaError.SemanticFailed;
                            }
                            break :blk if (binding.kind(context) == .ref) canonicalRefTarget(context, binding.type_id) else binding.type_id;
                        }
                        if (findGlobal(context, program, globals, current_module, assign.name)) |binding| {
                            try rejectIsolatedMutableGlobalAccess(context, path, assign.name_token, binding, "mutate");
                            if (!binding.is_mutable) {
                                try context.diagnostic_context.emitToken(path, assign.name_token, "cannot assign to const global `{s}`", .{assign.name});
                                return SemaError.SemanticFailed;
                            }
                            break :blk binding.type_id;
                        }
                        try emitUnknownValue(context, path, assign.name_token, locals.items, assign.name, .binding);
                        return SemaError.SemanticFailed;
                    };
                    if (target_local) |binding| {
                        if (binding.kind(context) != .ref) {
                            try rejectLiveBorrowInvalidation(context, path, locals.items, assign.name, assign.name_token, "rebind");
                        }
                    }

                    const value = try lowerExprInContext(context, allocator, path, program, current_module, globals, locals.items, assign.value, target_type);
                    errdefer value.expr.destroy(allocator);
                    try expectType(context, path, assign.name_token, target_type, value.type_id);
                    if (target_local) |binding| {
                        // A rebind joins what the binding can hold: a local written from
                        // two different binders admits a method use against each origin.
                        if (hasGenericReceiverOrigin(binding.generic_shape) or hasGenericReceiverOrigin(value.generic_shape)) {
                            locals.items[findLocalIndex(locals.items, assign.name).?].generic_shape = try genericShapeJoinReturns(context, binding.generic_shape, value.generic_shape);
                        }
                    }
                    if (target_local) |binding| {
                        const target_scope_depth = localMutationTargetScopeDepth(context, locals.items, binding);
                        if (binding.kind(context) == .ref) {
                            if (!provenanceOutlivesScope(locals.items, value.provenance, target_scope_depth)) {
                                try emitOwnershipDiagnostic(
                                    context,
                                    path,
                                    assign.name_token,
                                    .ownership_borrow_escape,
                                    provenanceRootToken(locals.items, value.provenance),
                                    "borrowed value is rooted here",
                                    "the assignment target outlives this borrow",
                                    "store an owned value or shorten the target lifetime",
                                    "borrowed values cannot escape into longer-lived state via assignment",
                                    .{},
                                );
                                return SemaError.SemanticFailed;
                            }
                        } else if (target_scope_depth < context.function_state.block_depth) {
                            try rejectBorrowedProvenanceAssignmentEscape(context, path, program, current_module, locals.items, assign.name_token, value, target_type, target_scope_depth);
                        }
                    } else if (findGlobal(context, program, globals, current_module, assign.name) != null) {
                        try rejectBorrowedProvenanceAssignmentEscape(context, path, program, current_module, locals.items, assign.name_token, value, target_type, 0);
                    }
                    if (context.function_state.scoped_alloc_depth > 0 and try exprCarriesScopedAllocAs(context, path, program, locals.items, assign.value, target_type)) {
                        if (target_local) |binding| {
                            if (localMutationTargetScopeDepth(context, locals.items, binding) < context.function_state.block_depth) {
                                try emitScopedAllocEscape(context, path, assign.name_token, firstExprToken(assign.value), "assignment");
                                return SemaError.SemanticFailed;
                            }
                        } else if (findGlobal(context, program, globals, current_module, assign.name) != null) {
                            try emitScopedAllocEscape(context, path, assign.name_token, firstExprToken(assign.value), "assignment");
                            return SemaError.SemanticFailed;
                        }
                    }
                    try rejectProjectedResourceTransferForTypedValue(context, path, program, assign.name_token, value, target_type, "assignment");
                    try lowerImplicitHandoff(context, path, program, locals.items, assign.value, target_type, value.expr);
                    try recordExprSink(context, value.expr, .replace);
                    try markCheckedNamedHandoff(context, path, program, locals.items, assign.value, value.expr, target_type);
                    if (target_local) |binding| {
                        const target_index = findLocalIndex(locals.items, assign.name).?;
                        if (binding.kind(context) == .ref) {
                            locals.items[target_index].provenance = value.provenance;
                            try accumulateBorrowRootMutationProvenance(locals.items, binding, value.provenance);
                        } else {
                            locals.items[target_index].provenance = value.provenance;
                            locals.items[target_index].borrowed_place = try checkedStoredBorrowDependency(context, path, program, current_module, globals, locals.items, assign.value, value.expr, target_type, value.provenance);
                            locals.items[target_index].projection_origin = assign.value;
                        }
                    }
                    const global_id: ?identity.DeclId = if (target_local == null) blk: {
                        const global = findGlobal(context, program, globals, current_module, assign.name) orelse break :blk null;
                        break :blk global.id;
                    } else null;
                    const target_root: ?sir.CheckedPlaceRoot = if (target_local) |binding|
                        (if (binding.kind(context) == .ref) null else if (binding.binding_id) |id| .{ .binding = id } else null)
                    else if (global_id) |id| .{ .global = id } else null;
                    const value_metadata = semanticExprMetadata(context, value.expr) orelse return error.SemanticFailed;
                    var checked_replace: ?sir.Record = null;
                    var checked_transfer: ?sir.Record = null;
                    if (target_root) |root| {
                        if (value_metadata.consumption.transfer == .move and
                            (value_metadata.semantics.ownership == .owned or value_metadata.semantics.ownership == .shared))
                        {
                            const temporary = value_metadata.temporary_id orelse return error.SemanticFailed;
                            const destination: sir.Subject = .{ .place = .{ .root = root, .projections = null, .non_owning = false } };
                            checked_replace = .{ .effect = .{ .replace = destination } };
                            checked_transfer = .{ .effect = .{ .move = .{
                                .source = .{ .temporary = temporary },
                                .destination = destination,
                            } } };
                        }
                    } else if (target_local) |binding| {
                        if (binding.kind(context) == .ref and
                            value_metadata.consumption.transfer == .move and
                            (value_metadata.semantics.ownership == .owned or value_metadata.semantics.ownership == .shared))
                        {
                            const destination: sir.Subject = .{ .alias_pointee = .{
                                .root = .{ .binding = binding.binding_id orelse return error.SemanticFailed },
                                .projections = null,
                                .non_owning = false,
                            } };
                            checked_replace = .{ .effect = .{ .replace = destination } };
                            checked_transfer = .{ .effect = .{ .move = .{
                                .source = .{ .temporary = value_metadata.temporary_id orelse return error.SemanticFailed },
                                .destination = destination,
                            } } };
                        }
                    }
                    return .{ .assign = .{
                        .name = assign.name,
                        .binding_id = if (target_local) |binding| binding.binding_id else null,
                        .global_decl_id = global_id,
                        .checked_non_owning_target = if (target_local) |binding| binding.kind(context) == .ref else false,
                        .value = value.expr,
                        .checked_replace = checked_replace,
                        .checked_transfer = checked_transfer,
                    } };
                },
                .field_assign => |assign| {
                    if (assign.object.* != .name) {
                        try context.diagnostic_context.emitToken(path, assign.token, "field assignment requires a local or global root place", .{});
                        return SemaError.SemanticFailed;
                    }
                    const root = assign.object.name;
                    const target_local = findLocal(locals.items, root.text);
                    if (target_local) |binding| {
                        if (binding.is_failure_view) {
                            try context.diagnostic_context.emitToken(path, root.token, "cannot mutate a failure view", .{});
                            return SemaError.SemanticFailed;
                        }
                    }
                    const root_type = blk: {
                        if (target_local) |binding| {
                            if (binding.is_unavailable) {
                                try emitUnavailableLocal(context, path, root.token, binding, false);
                                return SemaError.SemanticFailed;
                            }
                            if (binding.kind(context) == .ref and canonicalRefIsConst(context, binding.type_id)) {
                                try context.diagnostic_context.emitToken(path, root.token, "cannot assign through read-only alias `{s}`", .{root.text});
                                return SemaError.SemanticFailed;
                            }
                            if (binding.kind(context) != .ref and !binding.is_mutable and !binding.is_param) {
                                try context.diagnostic_context.emitToken(path, root.token, "cannot assign through const local `{s}`", .{root.text});
                                return SemaError.SemanticFailed;
                            }
                            break :blk if (binding.kind(context) == .ref)
                                canonicalRefTarget(context, binding.type_id)
                            else if (binding.kind(context) == .owned)
                                canonicalOwnedTarget(context, binding.type_id)
                            else
                                binding.type_id;
                        }
                        if (findGlobal(context, program, globals, current_module, root.text)) |binding| {
                            try rejectIsolatedMutableGlobalAccess(context, path, root.token, binding, "mutate");
                            if (!binding.is_mutable) {
                                try context.diagnostic_context.emitToken(path, root.token, "cannot assign through const global `{s}`", .{root.text});
                                return SemaError.SemanticFailed;
                            }
                            break :blk canonicalUnwrapOwned(context, binding.type_id);
                        }
                        try context.diagnostic_context.emitToken(path, root.token, "unknown binding `{s}`", .{root.text});
                        return SemaError.SemanticFailed;
                    };

                    var current_type = root_type;
                    try rejectLiveBorrowPlaceMutationConflict(context, path, program, current_module, globals, locals.items, assign.object, .{ .field = assign.fields[0].field }, root.text, assign.fields[0].field_token, "field-mutate");
                    var sir_steps: std.ArrayListUnmanaged(sir.StructFieldPathStep) = .empty;
                    errdefer sir_steps.deinit(allocator);
                    var checked_steps: std.ArrayListUnmanaged(sir.CheckedPlaceProjection) = .empty;
                    errdefer checked_steps.deinit(allocator);
                    for (assign.fields) |step| {
                        const resolved = typeStructField(context, path, program, current_module, current_type, step.field, step.field_token) catch |err| switch (err) {
                            SemaError.SemanticFailed => {
                                try context.diagnostic_context.emitToken(path, step.field_token, "field assignment path must stay within struct values", .{});
                                return SemaError.SemanticFailed;
                            },
                            else => return err,
                        };
                        current_type = resolved.field_type_id;
                        try sir_steps.append(allocator, .{
                            .struct_decl_id = resolved.struct_decl_id,
                            .struct_name = resolved.struct_name,
                            .field = step.field,
                        });
                        try checked_steps.append(allocator, .{
                            .step = .{ .field = .{ .owner_decl_id = resolved.struct_decl_id, .name = step.field } },
                            .result_type_id = current_type,
                        });
                    }
                    const field_type = current_type;
                    if (assign.capture) |capture| {
                        if (std.mem.eql(u8, capture.name, "_") or findLocal(locals.items, capture.name) != null) {
                            try context.diagnostic_context.emitToken(path, capture.name_token, "assignment capture requires a new named local", .{});
                            return SemaError.SemanticFailed;
                        }
                        try rejectArrowCallableStorageType(context, path, capture.name_token, field_type, "assignment capture");
                        if (try typeMayCarryBorrowedProvenance(context, path, program, current_module, field_type)) {
                            try context.diagnostic_context.emitToken(path, capture.name_token, "assignment capture of borrowed values is not supported", .{});
                            return SemaError.SemanticFailed;
                        }
                    }
                    const value = try lowerExprInContext(context, allocator, path, program, current_module, globals, locals.items, assign.value, field_type);
                    errdefer value.expr.destroy(allocator);
                    try expectType(context, path, firstExprToken(assign.value), field_type, value.type_id);
                    try rejectBorrowedProvenanceMutationEscape(context, path, program, current_module, globals, locals.items, assign.object, value, field_type, firstExprToken(assign.value), "field mutation");
                    try rejectScopedAllocMutationEscape(context, path, program, current_module, globals, locals.items, assign.object, assign.value, field_type, "field mutation");
                    try lowerImplicitHandoff(context, path, program, locals.items, assign.value, field_type, value.expr);
                    try recordExprSink(context, value.expr, .replace);
                    try markCheckedNamedHandoff(context, path, program, locals.items, assign.value, value.expr, field_type);
                    try recordMutationProvenance(context, program, current_module, globals, locals.items, assign.object, value.provenance);
                    const global_id: ?identity.DeclId = if (target_local == null) blk: {
                        const global = findGlobal(context, program, globals, current_module, root.text) orelse break :blk null;
                        break :blk global.id;
                    } else null;
                    const checked_projections = try checked_steps.toOwnedSlice(allocator);
                    errdefer allocator.free(checked_projections);
                    const value_metadata = semanticExprMetadata(context, value.expr) orelse return error.SemanticFailed;
                    var checked_replace: ?sir.Record = null;
                    var checked_transfer: ?sir.Record = null;
                    if (value_metadata.consumption.transfer == .move and
                        (value_metadata.semantics.ownership == .owned or value_metadata.semantics.ownership == .shared))
                    {
                        const target_root: sir.CheckedPlaceRoot = if (target_local) |binding|
                            .{ .binding = binding.binding_id orelse return error.SemanticFailed }
                        else
                            .{ .global = global_id orelse return error.SemanticFailed };
                        const destination_path: sir.CheckedPlacePath = .{ .root = target_root, .projections = checked_projections, .non_owning = false };
                        const destination: sir.Subject = if (target_local != null and target_local.?.kind(context) == .ref)
                            .{ .alias_pointee = destination_path }
                        else
                            .{ .place = destination_path };
                        checked_replace = .{ .effect = .{ .replace = destination } };
                        checked_transfer = .{ .effect = .{ .move = .{
                            .source = .{ .temporary = value_metadata.temporary_id orelse return error.SemanticFailed },
                            .destination = destination,
                        } } };
                    }
                    var lowered_assign: sir.FieldAssign = .{
                        .root_name = root.text,
                        .root_binding_id = if (target_local) |binding| binding.binding_id else null,
                        .root_global_decl_id = global_id,
                        .steps = try sir_steps.toOwnedSlice(allocator),
                        .checked_projections = checked_projections,
                        .value = value.expr,
                        .checked_replace = checked_replace,
                        .checked_transfer = checked_transfer,
                    };
                    lowered_assign.checked_evaluation_sites[0] = .{ .assigned_value = value.expr };
                    lowered_assign.checked_evaluation_sites_len = 1;
                    if (checked_replace) |record| {
                        lowered_assign.checked_evaluation_sites[1] = .{ .effect = record };
                        lowered_assign.checked_evaluation_sites[2] = .{ .effect = checked_transfer.? };
                        lowered_assign.checked_evaluation_sites_len = 3;
                    }
                    if (assign.capture) |capture| {
                        var binding = try localBinding(context, capture.name, field_type, false, capture.is_mutable);
                        binding.declaration_token = capture.name_token;
                        binding.generic_shape = try shapeFromCanonicalType(context, field_type, false);
                        if (target_local) |root_binding| {
                            binding.is_scoped_alloc_value = root_binding.is_scoped_alloc_value and
                                try typeMayCaptureAllocator(context, path, program, field_type);
                            if (binding.is_scoped_alloc_value) binding.scoped_alloc_origin = assign.object;
                        }
                        try locals.append(allocator, binding);
                        lowered_assign.capture = .{
                            .name = capture.name,
                            .binding_id = binding.binding_id orelse return error.SemanticFailed,
                            .type_id = field_type,
                            .is_mutable = capture.is_mutable,
                        };
                        if (try typeIsOwnedValue(context, path, program, field_type)) {
                            const source_root: sir.CheckedPlaceRoot = if (target_local) |local|
                                .{ .binding = local.binding_id orelse return error.SemanticFailed }
                            else
                                .{ .global = global_id orelse return error.SemanticFailed };
                            const source_path: sir.CheckedPlacePath = .{ .root = source_root, .projections = checked_projections, .non_owning = false };
                            const source: sir.Subject = if (target_local != null and target_local.?.kind(context) == .ref)
                                .{ .alias_pointee = source_path }
                            else
                                .{ .place = source_path };
                            lowered_assign.checked_capture = .{ .effect = .{ .take = .{
                                .source = source,
                                .destination = .{ .place = .{ .root = .{ .binding = binding.binding_id.? }, .projections = null, .non_owning = false } },
                            } } };
                            if (lowered_assign.checked_evaluation_sites_len == 3) {
                                lowered_assign.checked_evaluation_sites[3] = lowered_assign.checked_evaluation_sites[2];
                                lowered_assign.checked_evaluation_sites[2] = lowered_assign.checked_evaluation_sites[1];
                            }
                            lowered_assign.checked_evaluation_sites[1] = .{ .effect = lowered_assign.checked_capture.? };
                            lowered_assign.checked_evaluation_sites_len += 1;
                        }
                    }
                    return .{ .field_assign = lowered_assign };
                },
                .index_assign => |assign| {
                    const object = try lowerExpr(context, allocator, path, program, current_module, globals, locals.items, assign.object, null);
                    errdefer object.expr.destroy(allocator);
                    try recordLoweredOperationUse(context, "index_assign", firstExprToken(assign.object), object);
                    if (canonicalSliceIsConst(context, object.type_id)) {
                        try context.diagnostic_context.emitToken(path, assign.token, "cannot assign through read-only slice", .{});
                        return SemaError.SemanticFailed;
                    }
                    if (type_resolution.typeIndexedAssignmentRoot(typeConstructionContext(context), object.type_id) and assign.object.* == .name) {
                        const target = assign.object.name;
                        if (findLocal(locals.items, target.text)) |binding| {
                            if (binding.kind(context) != .ref and binding.kind(context) != .slice and !binding.is_mutable and !binding.is_param) {
                                const object_name = try formatCanonicalTypeDisplay(context, object.type_id);
                                defer allocator.free(object_name);
                                try context.diagnostic_context.emitToken(path, target.token, "cannot assign through const {s} `{s}`", .{ object_name, target.text });
                                return SemaError.SemanticFailed;
                            }
                        } else if (findGlobal(context, program, globals, current_module, target.text)) |binding| {
                            try rejectIsolatedMutableGlobalAccess(context, path, target.token, binding, "mutate");
                            if (!binding.is_mutable) {
                                const object_name = try formatCanonicalTypeDisplay(context, object.type_id);
                                defer allocator.free(object_name);
                                try context.diagnostic_context.emitToken(path, target.token, "cannot assign through const {s} `{s}`", .{ object_name, target.text });
                                return SemaError.SemanticFailed;
                            }
                        }
                    }
                    const index_role = (try type_resolution.typeIndexAccessRole(typeConstructionContext(context), object.type_id)) orelse {
                        if (selectSyntaxMethod(context, program, current_module, object.type_id, .index_set)) |method| {
                            try rejectLiveBorrowPlaceMutationConflict(context, path, program, current_module, globals, locals.items, assign.object, .{ .index = constIndexValue(assign.index) }, "indexed place", assign.token, "index-mutate");
                            const out = try allocator.create(sir.Expr);
                            var hook_args = [_]ast.CallArg{
                                .{ .value = assign.index },
                                .{ .value = assign.value },
                            };
                            const hook_call = ast.MethodCall{
                                .object = assign.object,
                                .method = method.name,
                                .method_token = assign.token,
                                .type_args = &.{},
                                .args = &hook_args,
                            };
                            var lowered = try lowerMethodCallInternal(context, allocator, path, program, current_module, globals, locals.items, out, hook_call, null);
                            try finalizeAndRecordExprSemantics(context, path, program, current_module, &lowered);
                            object.expr.destroy(allocator);
                            if (lowered.kind(context) != .void) {
                                lowered.expr.destroy(allocator);
                                try context.diagnostic_context.emitToken(path, assign.token, "`syntax.index_set` must return void", .{});
                                return SemaError.SemanticFailed;
                            }
                            return .{ .expr = lowered.expr };
                        }
                        try context.diagnostic_context.emitToken(path, assign.token, "indexed assignment requires an indexable foundation type or an accessible `syntax.index_set` method", .{});
                        return SemaError.SemanticFailed;
                    };
                    try expectMutablePlaceRoot(context, path, program, current_module, globals, locals.items, assign.object, object.type_id, "indexed place");
                    const item_type = index_role.value_type_id;
                    const index_type = index_role.key_type_id;
                    const index = try lowerExprInContext(context, allocator, path, program, current_module, globals, locals.items, assign.index, index_role.key_type_id);
                    errdefer index.expr.destroy(allocator);
                    try expectType(context, path, firstExprToken(assign.index), index_type, index.type_id);
                    try rejectLiveBorrowPlaceMutationConflict(context, path, program, current_module, globals, locals.items, assign.object, .{ .index = constIndexValue(assign.index) }, "indexed place", assign.token, "index-mutate");
                    const value = try lowerExprInContext(context, allocator, path, program, current_module, globals, locals.items, assign.value, index_role.value_type_id);
                    errdefer value.expr.destroy(allocator);
                    try expectType(context, path, firstExprToken(assign.value), item_type, value.type_id);
                    try rejectBorrowedProvenanceMutationEscape(context, path, program, current_module, globals, locals.items, assign.object, value, item_type, firstExprToken(assign.value), "indexed mutation");
                    try rejectScopedAllocMutationEscape(context, path, program, current_module, globals, locals.items, assign.object, assign.value, item_type, "indexed mutation");
                    try lowerImplicitHandoff(context, path, program, locals.items, assign.value, index_role.value_type_id, value.expr);
                    try recordExprSink(context, value.expr, .replace);
                    try markCheckedNamedHandoff(context, path, program, locals.items, assign.value, value.expr, index_role.value_type_id);
                    try recordMutationProvenance(context, program, current_module, globals, locals.items, assign.object, value.provenance);
                    const object_metadata = semanticExprMetadata(context, object.expr) orelse return error.SemanticFailed;
                    const value_metadata = semanticExprMetadata(context, value.expr) orelse return error.SemanticFailed;
                    var checked_projections: ?[]const sir.CheckedPlaceProjection = null;
                    var checked_replace: ?sir.Record = null;
                    var checked_transfer: ?sir.Record = null;
                    if (object_metadata.checkedPlacePath()) |object_path| {
                        const alias_destination = object_path.non_owning and switch (object_path.root) {
                            .binding => |id| blk: {
                                for (locals.items) |local| {
                                    if (local.binding_id == id) break :blk local.kind(context) == .ref;
                                }
                                break :blk false;
                            },
                            .global => false,
                        };
                        if ((!object_path.non_owning or alias_destination) and value_metadata.consumption.transfer == .move and
                            (value_metadata.semantics.ownership == .owned or value_metadata.semantics.ownership == .shared))
                        {
                            const prefix = object_path.projections orelse &.{};
                            const projections = try allocator.alloc(sir.CheckedPlaceProjection, prefix.len + 1);
                            errdefer allocator.free(projections);
                            @memcpy(projections[0..prefix.len], prefix);
                            projections[prefix.len] = .{
                                .step = .{ .index = if (index.expr.* == .int and index.expr.int.value >= 0)
                                    .{ .fixed = index.expr.int.value }
                                else
                                    .{ .dynamic = index.expr } },
                                .result_type_id = item_type,
                            };
                            checked_projections = projections;
                            const destination_path: sir.CheckedPlacePath = .{
                                .root = object_path.root,
                                .projections = projections,
                                .non_owning = false,
                            };
                            const destination: sir.Subject = if (alias_destination)
                                .{ .alias_pointee = destination_path }
                            else
                                .{ .place = destination_path };
                            checked_replace = .{ .effect = .{ .replace = destination } };
                            checked_transfer = .{ .effect = .{ .move = .{
                                .source = .{ .temporary = value_metadata.temporary_id orelse return error.SemanticFailed },
                                .destination = destination,
                            } } };
                        }
                    }
                    var lowered_assign: sir.IndexAssign = .{
                        .object = object.expr,
                        .index = index.expr,
                        .value = value.expr,
                        .checked_projections = checked_projections,
                        .checked_replace = checked_replace,
                        .checked_transfer = checked_transfer,
                    };
                    lowered_assign.checked_evaluation_sites[0] = .{ .target_value = object.expr };
                    lowered_assign.checked_evaluation_sites[1] = .{ .index_value = index.expr };
                    lowered_assign.checked_evaluation_sites[2] = .{ .assigned_value = value.expr };
                    lowered_assign.checked_evaluation_sites_len = 3;
                    if (checked_replace) |record| {
                        lowered_assign.checked_evaluation_sites[3] = .{ .effect = record };
                        lowered_assign.checked_evaluation_sites[4] = .{ .effect = checked_transfer.? };
                        lowered_assign.checked_evaluation_sites_len = 5;
                    }
                    return .{ .index_assign = lowered_assign };
                },
                .deref_assign => |assign| {
                    const pointer = try lowerExpr(context, allocator, path, program, current_module, globals, locals.items, assign.pointer, null);
                    errdefer pointer.expr.destroy(allocator);
                    if (canonicalTypeNode(context, pointer.type_id).* != .raw) {
                        try context.diagnostic_context.emitToken(path, assign.token, "raw pointer assignment requires raw pointer target", .{});
                        return SemaError.SemanticFailed;
                    }
                    const raw = canonicalTypeNode(context, pointer.type_id).raw;
                    if (raw.is_const) {
                        try context.diagnostic_context.emitToken(path, assign.token, "cannot assign through `*const` raw pointer", .{});
                        return SemaError.SemanticFailed;
                    }
                    const target_type = raw.target;
                    if (raw.is_volatile and try typeIsOwnedValue(context, path, program, target_type)) {
                        try context.diagnostic_context.emitToken(path, assign.token, "volatile raw-pointer assignment cannot replace an owned value", .{});
                        return SemaError.SemanticFailed;
                    }
                    const value = try lowerExprInContext(context, allocator, path, program, current_module, globals, locals.items, assign.value, raw.target);
                    errdefer value.expr.destroy(allocator);
                    try expectType(context, path, firstExprToken(assign.value), target_type, value.type_id);
                    try lowerImplicitHandoff(context, path, program, locals.items, assign.value, raw.target, value.expr);
                    try recordExprSink(context, value.expr, .replace);
                    try markCheckedNamedHandoff(context, path, program, locals.items, assign.value, value.expr, raw.target);
                    const value_metadata = semanticExprMetadata(context, value.expr) orelse return error.SemanticFailed;
                    var checked_replace: ?sir.Record = null;
                    var checked_transfer: ?sir.Record = null;
                    if (value_metadata.consumption.transfer == .move and
                        (value_metadata.semantics.ownership == .owned or value_metadata.semantics.ownership == .shared))
                    {
                        const destination: sir.Subject = .{ .raw_pointee = .{
                            .pointer = pointer.expr,
                            .pointee_type_id = target_type,
                        } };
                        checked_replace = .{ .effect = .{ .replace = destination } };
                        checked_transfer = .{ .effect = .{ .move = .{
                            .source = .{ .temporary = value_metadata.temporary_id orelse return error.SemanticFailed },
                            .destination = destination,
                        } } };
                    }
                    return .{ .deref_assign = .{
                        .pointer = pointer.expr,
                        .value = value.expr,
                        .is_volatile = raw.is_volatile,
                        .checked_replace = checked_replace,
                        .checked_transfer = checked_transfer,
                    } };
                },
                .deref_field_assign => |assign| {
                    const pointer = try lowerExpr(context, allocator, path, program, current_module, globals, locals.items, assign.pointer, null);
                    errdefer pointer.expr.destroy(allocator);
                    if (canonicalTypeNode(context, pointer.type_id).* != .raw) {
                        try context.diagnostic_context.emitToken(path, assign.token, "raw field assignment requires raw pointer target", .{});
                        return SemaError.SemanticFailed;
                    }
                    const raw = canonicalTypeNode(context, pointer.type_id).raw;
                    if (raw.is_const) {
                        try context.diagnostic_context.emitToken(path, assign.token, "cannot assign through `*const` raw pointer", .{});
                        return SemaError.SemanticFailed;
                    }
                    const target_type = raw.target;
                    if (canonicalTypeKind(context, target_type) != .@"struct") {
                        try context.diagnostic_context.emitToken(path, assign.token, "raw field assignment requires pointer to struct", .{});
                        return SemaError.SemanticFailed;
                    }

                    var current_type = target_type;
                    var sir_steps: std.ArrayListUnmanaged(sir.StructFieldPathStep) = .empty;
                    errdefer sir_steps.deinit(allocator);
                    var checked_steps: std.ArrayListUnmanaged(sir.CheckedPlaceProjection) = .empty;
                    errdefer checked_steps.deinit(allocator);
                    for (assign.fields) |step| {
                        if (canonicalTypeKind(context, current_type) != .@"struct") {
                            try context.diagnostic_context.emitToken(path, step.field_token, "raw field assignment path must stay within struct values", .{});
                            return SemaError.SemanticFailed;
                        }
                        const struct_name = canonicalNominalDeclName(context, program, current_type) orelse return error.SemanticFailed;
                        const struct_decl_id = canonicalNominalDeclId(context, current_type) orelse return error.SemanticFailed;
                        const decl = lookupStructDeclById(context, program, struct_decl_id) orelse return error.SemanticFailed;
                        const decl_field = lookupStructField(decl, step.field) orelse {
                            try context.diagnostic_context.emitToken(path, step.field_token, "struct `{s}` has no field `{s}`", .{ struct_name, step.field });
                            return SemaError.SemanticFailed;
                        };
                        if (!canAccessDecl(context, current_module, decl.module_name, decl_field.is_pub)) {
                            try context.diagnostic_context.emitToken(path, step.field_token, "field `{s}` of struct `{s}` is not public", .{ step.field, struct_name });
                            return SemaError.SemanticFailed;
                        }
                        current_type = try structFieldTypeId(context, path, program, decl, decl_field);
                        try sir_steps.append(allocator, .{
                            .struct_decl_id = struct_decl_id,
                            .struct_name = struct_name,
                            .field = step.field,
                        });
                        try checked_steps.append(allocator, .{
                            .step = .{ .field = .{ .owner_decl_id = struct_decl_id, .name = step.field } },
                            .result_type_id = current_type,
                        });
                    }

                    const field_type = current_type;
                    const value = try lowerExprInContext(context, allocator, path, program, current_module, globals, locals.items, assign.value, field_type);
                    errdefer value.expr.destroy(allocator);
                    try expectType(context, path, firstExprToken(assign.value), field_type, value.type_id);
                    try lowerImplicitHandoff(context, path, program, locals.items, assign.value, field_type, value.expr);
                    try recordExprSink(context, value.expr, .replace);
                    try markCheckedNamedHandoff(context, path, program, locals.items, assign.value, value.expr, field_type);
                    const projections = try checked_steps.toOwnedSlice(allocator);
                    errdefer allocator.free(projections);
                    const value_metadata = semanticExprMetadata(context, value.expr) orelse return error.SemanticFailed;
                    var checked_replace: ?sir.Record = null;
                    var checked_transfer: ?sir.Record = null;
                    if (value_metadata.consumption.transfer == .move and
                        (value_metadata.semantics.ownership == .owned or value_metadata.semantics.ownership == .shared))
                    {
                        const destination: sir.Subject = .{ .raw_pointee = .{
                            .pointer = pointer.expr,
                            .pointee_type_id = target_type,
                            .projections = projections,
                        } };
                        checked_replace = .{ .effect = .{ .replace = destination } };
                        checked_transfer = .{ .effect = .{ .move = .{
                            .source = .{ .temporary = value_metadata.temporary_id orelse return error.SemanticFailed },
                            .destination = destination,
                        } } };
                    }
                    return .{ .deref_field_assign = .{
                        .pointer = pointer.expr,
                        .steps = try sir_steps.toOwnedSlice(allocator),
                        .value = value.expr,
                        .is_volatile = raw.is_volatile,
                        .checked_projections = projections,
                        .checked_replace = checked_replace,
                        .checked_transfer = checked_transfer,
                    } };
                },
                .using_alloc => |using_alloc| {
                    const allocator_expr = try lowerExpr(context, allocator, path, program, current_module, globals, locals.items, using_alloc.allocator_expr, null);
                    errdefer allocator_expr.expr.destroy(allocator);
                    const body = if (using_alloc.is_scoped) blk: {
                        const prev_region_depth = context.function_state.scoped_alloc_region_depth;
                        context.function_state.scoped_alloc_region_depth = context.function_state.block_depth + 1;
                        defer context.function_state.scoped_alloc_region_depth = prev_region_depth;
                        context.function_state.scoped_alloc_depth += 1;
                        defer context.function_state.scoped_alloc_depth -= 1;
                        break :blk try lowerBlock(context, allocator, path, program, current_module, globals, return_type, locals, using_alloc.body);
                    } else try lowerBlock(context, allocator, path, program, current_module, globals, return_type, locals, using_alloc.body);
                    return .{ .using_alloc = .{
                        .is_scoped = using_alloc.is_scoped,
                        .allocator_expr = allocator_expr.expr,
                        .body = body,
                    } };
                },
                .@"if" => |if_stmt| {
                    if (if_stmt.condition.* == .is_test) {
                        return lowerNarrowIf(context, allocator, path, program, current_module, globals, return_type, locals, if_stmt, false);
                    }
                    if (if_stmt.condition.* == .name) {
                        const name = if_stmt.condition.name;
                        if (optionalLocalPayload(context, locals.items, name) != null) {
                            var subject: ast.Expr = .{ .name = name };
                            var condition: ast.Expr = .{ .is_test = .{
                                .subject = &subject,
                                .kind = .optional_some,
                                .case_name = null,
                                .capture_name = name.text,
                                .token = name.token,
                            } };
                            var positive = if_stmt;
                            positive.condition = &condition;
                            return lowerNarrowIf(context, allocator, path, program, current_module, globals, return_type, locals, positive, true);
                        }
                    }
                    const condition = try lowerExpr(context, allocator, path, program, current_module, globals, locals.items, if_stmt.condition, try canonicalPrimitiveTypeId(context, .bool));
                    errdefer condition.expr.destroy(allocator);
                    try expectType(context, path, firstExprToken(if_stmt.condition), try canonicalPrimitiveTypeId(context, .bool), condition.type_id);
                    const lowered_bodies = try lowerJoinedIfBodies(
                        context,
                        allocator,
                        path,
                        program,
                        current_module,
                        globals,
                        return_type,
                        locals,
                        if_stmt.then_body,
                        if_stmt.else_body,
                        null,
                    );
                    return .{ .@"if" = .{
                        .kind = .plain,
                        .condition = condition.expr,
                        .union_decl_id = null,
                        .case_name = null,
                        .capture_name = null,
                        .capture_type_id = null,
                        .then_body = lowered_bodies.then_body,
                        .else_body = lowered_bodies.else_body,
                    } };
                },
                .@"while" => |while_stmt| {
                    const condition = try lowerExpr(context, allocator, path, program, current_module, globals, locals.items, while_stmt.condition, try canonicalPrimitiveTypeId(context, .bool));
                    errdefer condition.expr.destroy(allocator);
                    try expectType(context, path, firstExprToken(while_stmt.condition), try canonicalPrimitiveTypeId(context, .bool), condition.type_id);
                    context.function_state.loop_depth += 1;
                    defer context.function_state.loop_depth -= 1;
                    const lowered_body = try lowerFixedPointLoopBody(
                        context,
                        allocator,
                        path,
                        program,
                        current_module,
                        globals,
                        return_type,
                        locals,
                        while_stmt.body,
                        locals.items.len,
                        locals.items.len,
                    );
                    defer allocator.free(lowered_body.state);
                    return .{ .@"while" = .{
                        .condition = condition.expr,
                        .body = lowered_body.body,
                    } };
                },
                .@"for" => |for_stmt| {
                    if (findLocal(locals.items, for_stmt.name) != null) {
                        try context.diagnostic_context.emitToken(path, for_stmt.name_token, "duplicate local `{s}`", .{for_stmt.name});
                        return SemaError.SemanticFailed;
                    }
                    const iterable = try lowerExpr(context, allocator, path, program, current_module, globals, locals.items, for_stmt.iterable, null);
                    errdefer iterable.expr.destroy(allocator);
                    try recordLoweredOperationUse(context, "iterate", firstExprToken(for_stmt.iterable), iterable);
                    // A binder iterable stands for an unknown concrete type: the loop
                    // cannot reach a real iterator foundation yet, so the trial body
                    // lowers the loop body once with the item bound to the binder.
                    const iterable_type = try iterable.canonicalTypeId(context);
                    if (isDefinitionSiteBinder(context, iterable_type)) {
                        var binding = try localBinding(context, for_stmt.name, iterable_type, false, false);
                        binding.generic_shape = try loweredProjectionShape(context, iterable.generic_shape, iterable_type, .iter_item);
                        binding.generic_origin = projectedOrigin(iterable.generic_origin);
                        binding.provenance = iterable.provenance.derived();
                        binding.is_for_binding = true;
                        const loop_head = locals.items.len;
                        try locals.append(allocator, binding);
                        defer locals.items.len -= 1;
                        context.function_state.loop_depth += 1;
                        defer context.function_state.loop_depth -= 1;
                        const lowered_body = try lowerFixedPointLoopBody(context, allocator, path, program, current_module, globals, return_type, locals, for_stmt.body, loop_head, loop_head);
                        allocator.free(lowered_body.state);
                        iterable.expr.destroy(allocator);
                        return .{ .unchecked = lowered_body.body };
                    }
                    var iterator_state_type_id = iterable.type_id;
                    var iterator_cursor_type_id: ?semantic_types.TypeId = null;
                    var iterator_init_decl_id: ?identity.DeclId = null;
                    var iterator_has_next_decl_id: ?identity.DeclId = null;
                    var iterator_next_decl_id: ?identity.DeclId = null;
                    var iterable_index_decl_id: ?identity.DeclId = null;
                    var generated_method_uses: []sir.GeneratedMethodUse = &.{};
                    const item_type_id = if (try type_resolution.typeIterationRole(typeConstructionContext(context), iterable.type_id)) |iteration_role|
                        iteration_role.item_type_id
                    else blk: {
                        if (try typeIteratorInitRole(context, allocator, path, program, current_module, globals, iterable.type_id)) |init_role| {
                            iterator_state_type_id = init_role.iterator_type_id;
                            iterator_init_decl_id = init_role.init_decl_id;
                            const iterator_role = (try typeIteratorHookRole(context, allocator, path, program, current_module, globals, iterable.type_id, iterator_state_type_id)) orelse {
                                try context.diagnostic_context.emitToken(path, firstExprToken(for_stmt.iterable), "`syntax.iter*` methods is missing its state operations", .{});
                                return SemaError.SemanticFailed;
                            };
                            iterator_cursor_type_id = iterator_role.cursor_type_id;
                            iterator_has_next_decl_id = iterator_role.has_next_decl_id;
                            iterator_next_decl_id = iterator_role.next_decl_id;
                            if (selectSyntaxMethod(context, program, current_module, iterable.type_id, .iter_item)) |item_method| {
                                const index_return_type = try syntaxMethodReturnType(context, path, program, iterable.type_id, item_method);
                                const item_type_id = if (canonicalTypeKind(context, index_return_type) == .ref)
                                    canonicalRefTarget(context, index_return_type)
                                else
                                    index_return_type;
                                if (canonicalTypeKind(context, index_return_type) != .ref and try typeIsOwnedValue(context, path, program, item_type_id)) {
                                    const item_type_name = try formatTypeDisplay(context, item_type_id);
                                    defer allocator.free(item_type_name);
                                    try context.diagnostic_context.emitTokenWith(path, for_stmt.name_token, .{
                                        .code = .ownership,
                                        .notes = &.{"the `syntax.iter_item` method returns its item by value"},
                                        .help = "iterate a borrowed-index container or use an operation that does not copy resource elements",
                                    }, "cannot iterate resource item type `{s}` through a by-value index hook", .{item_type_name});
                                    return SemaError.SemanticFailed;
                                }
                            }
                            const read_role = (try typeIteratorReadRole(context, allocator, path, program, current_module, globals, iterable.type_id, iterator_role.cursor_type_id)) orelse {
                                try context.diagnostic_context.emitToken(path, firstExprToken(for_stmt.iterable), "`syntax.iter*` methods is missing its item operation", .{});
                                return SemaError.SemanticFailed;
                            };
                            iterable_index_decl_id = read_role.index_decl_id;
                            // The four hooks are generated, not written in the source,
                            // but each is a method use with its own checked identity,
                            // signature, and specialization.
                            const source_declaration_id = context.function_state.active_source_decl_id orelse return SemaError.SemanticFailed;
                            const hooks = [_]IteratorHookSource{
                                .{ .role = .iterator_init, .declaration_id = init_role.init_decl_id, .result_type_id = init_role.iterator_type_id, .args = init_role.args },
                                .{ .role = .iterator_has_next, .declaration_id = iterator_role.has_next_decl_id, .result_type_id = try canonicalPrimitiveTypeId(context, .bool), .args = iterator_role.has_next_args },
                                .{ .role = .iterator_next, .declaration_id = iterator_role.next_decl_id, .result_type_id = iterator_role.cursor_type_id, .args = iterator_role.next_args },
                                .{ .role = .iterable_item, .declaration_id = read_role.index_decl_id orelse return SemaError.SemanticFailed, .result_type_id = read_role.result_type_id, .args = read_role.args },
                            };
                            const records = try context.allocator.alloc(sir.GeneratedMethodUse, hooks.len);
                            var record_count: usize = 0;
                            errdefer {
                                for (records[0..record_count]) |use| if (use.substitution.len != 0) context.allocator.free(use.substitution);
                                context.allocator.free(records);
                            }
                            const hook_offset = firstExprToken(for_stmt.iterable).offset;
                            for (hooks, 0..) |hook, index| {
                                records[index] = .{
                                    .use_id = context.generic.next_generated_use_id,
                                    .role = hook.role,
                                    .source_declaration_id = source_declaration_id,
                                    .source_offset = hook_offset,
                                    .subject_type_id = iterable.type_id,
                                    .receiver_type_id = iterable.type_id,
                                    .method_declaration_id = hook.declaration_id,
                                    .result_type_id = hook.result_type_id,
                                    .substitution = try specializationTypeIds(context.allocator, hook.args),
                                };
                                record_count += 1;
                                context.generic.next_generated_use_id += 1;
                            }
                            generated_method_uses = records;
                            break :blk read_role.item_type_id;
                        }
                        try context.diagnostic_context.emitToken(path, firstExprToken(for_stmt.iterable), "for loop requires an iterable foundation type or `syntax.iter*` methods", .{});
                        return SemaError.SemanticFailed;
                    };
                    const item_type = item_type_id;
                    errdefer {
                        for (generated_method_uses) |use| if (use.substitution.len != 0) allocator.free(use.substitution);
                        if (generated_method_uses.len != 0) allocator.free(generated_method_uses);
                    }
                    var binding = try localBinding(context, for_stmt.name, item_type, false, false);
                    binding.generic_shape = try loweredProjectionShape(context, iterable.generic_shape, item_type, .iter_item);
                    binding.generic_origin = receiverOriginFromType(context, item_type);
                    binding.provenance = iterable.provenance.derived();
                    binding.borrowed_place = try borrowedPlaceDependencyForStoredValue(context, path, program, current_module, globals, locals.items, for_stmt.iterable, item_type, binding.provenance);
                    binding.is_for_binding = true;
                    const outer_len = locals.items.len;
                    try locals.append(allocator, binding);
                    defer locals.items.len -= 1;
                    context.function_state.loop_depth += 1;
                    defer context.function_state.loop_depth -= 1;
                    const lowered_body = try lowerFixedPointLoopBody(
                        context,
                        allocator,
                        path,
                        program,
                        current_module,
                        globals,
                        return_type,
                        locals,
                        for_stmt.body,
                        locals.items.len,
                        outer_len,
                    );
                    defer allocator.free(lowered_body.state);

                    return .{ .@"for" = .{
                        .name = for_stmt.name,
                        .binding_id = binding.binding_id,
                        .item_type_id = item_type_id,
                        .iterable = iterable.expr,
                        .iterator_state_type_id = iterator_state_type_id,
                        .iterator_cursor_type_id = iterator_cursor_type_id,
                        .iterator_init_decl_id = iterator_init_decl_id,
                        .iterator_init_intrinsic_id = if (iterator_init_decl_id != null) .syntax_iter else null,
                        .iterator_has_next_decl_id = iterator_has_next_decl_id,
                        .iterator_has_next_intrinsic_id = if (iterator_has_next_decl_id != null) .syntax_iter_has_next else null,
                        .iterator_next_decl_id = iterator_next_decl_id,
                        .iterator_next_intrinsic_id = if (iterator_next_decl_id != null) .syntax_iter_next else null,
                        .iterable_index_decl_id = iterable_index_decl_id,
                        .iterable_index_intrinsic_id = if (iterable_index_decl_id != null) .syntax_iter_item else null,
                        .generated_method_uses = generated_method_uses,
                        .body = lowered_body.body,
                    } };
                },
                .@"continue" => |token| {
                    if (context.function_state.loop_depth == 0) {
                        try context.diagnostic_context.emitToken(path, token, "`continue` is only valid inside a loop", .{});
                        return SemaError.SemanticFailed;
                    }
                    return .{ .@"continue" = {} };
                },
                .@"break" => |token| {
                    if (context.function_state.loop_depth == 0) {
                        try context.diagnostic_context.emitToken(path, token, "`break` is only valid inside a loop", .{});
                        return SemaError.SemanticFailed;
                    }
                    return .{ .@"break" = {} };
                },
                .@"switch" => |switch_stmt| return lowerSwitch(context, allocator, path, program, current_module, globals, return_type, locals, switch_stmt, null),
                .yield => |yield_stmt| {
                    const target = context.function_state.active_switch_yield orelse {
                        try context.diagnostic_context.emitToken(path, yield_stmt.token, "`yield` is only valid inside a switch arm", .{});
                        return SemaError.SemanticFailed;
                    };
                    if (yield_stmt.value) |expr| {
                        const expected = target.result_type_id orelse target.expected_type_id;
                        const value = try lowerExprInContext(context, allocator, path, program, current_module, globals, locals.items, expr, expected);
                        errdefer value.expr.destroy(allocator);
                        // A terminal expression exits the arm before it can yield a value.
                        if (sir.exprDefinitelyDiverges(value.expr)) return .{ .expr = value.expr };
                        if (!target.value_required and !canonicalTypeIsVoidLike(context, value.type_id)) {
                            try context.diagnostic_context.emitToken(path, yield_stmt.token, "statement-used switch arms cannot yield a non-void value", .{});
                            return SemaError.SemanticFailed;
                        }
                        if (expected) |ty| {
                            try expectType(context, path, firstExprToken(expr), ty, value.type_id);
                        } else {
                            target.result_type_id = value.type_id;
                        }
                        if (target.value_required and value.provenance.hasBorrow()) {
                            if (!provenanceOutlivesScope(locals.items, value.provenance, target.scope_depth)) {
                                try emitOwnershipDiagnostic(context, path, firstExprToken(expr), .ownership_borrow_escape, provenanceRootToken(locals.items, value.provenance), "borrowed value is rooted here", "the switch result may outlive this arm", "yield owned data or borrow from an outer scope", "borrowed values cannot escape a switch arm", .{});
                                return SemaError.SemanticFailed;
                            }
                            target.provenance = Provenance.combine(target.provenance, value.provenance);
                        }
                        if (target.value_required and context.function_state.scoped_alloc_depth > target.scoped_alloc_depth and
                            canonicalTypeKind(context, target.result_type_id orelse value.type_id) != .raw and
                            try exprCarriesScopedAllocAs(context, path, program, locals.items, expr, target.result_type_id orelse value.type_id))
                        {
                            try emitScopedAllocEscape(context, path, firstExprToken(expr), null, "yield");
                            return SemaError.SemanticFailed;
                        }
                        try rejectProjectedResourceTransferForTypedValue(context, path, program, firstExprToken(expr), value, target.result_type_id orelse value.type_id, "yield");
                        try lowerImplicitHandoff(context, path, program, locals.items, expr, target.result_type_id orelse value.type_id, value.expr);
                        try recordExprSink(context, value.expr, .@"return");
                        try markCheckedNamedHandoff(context, path, program, locals.items, expr, value.expr, target.result_type_id orelse value.type_id);
                        return .{ .yield = value.expr };
                    }
                    const void_ty = try canonicalPrimitiveTypeId(context, .void);
                    if (target.value_required) {
                        if (target.result_type_id orelse target.expected_type_id) |ty| {
                            try expectType(context, path, yield_stmt.token, ty, void_ty);
                        } else {
                            target.result_type_id = void_ty;
                        }
                    }
                    return .{ .yield = null };
                },
                .@"try" => |expr| {
                    if (canonicalTypeKind(context, return_type) != .result) {
                        try context.diagnostic_context.emitToken(path, firstExprToken(expr), "`try` statement requires a result return type; optional absence must be tested and returned as `none` explicitly", .{});
                        return SemaError.SemanticFailed;
                    }
                    const value = try lowerExpr(context, allocator, path, program, current_module, globals, locals.items, expr, null);
                    errdefer value.expr.destroy(allocator);
                    if (value.kind(context) != .result) {
                        try context.diagnostic_context.emitToken(path, firstExprToken(expr), "`try` requires a result value", .{});
                        return SemaError.SemanticFailed;
                    }
                    const return_result = canonicalTypeNode(context, return_type).result;
                    const value_result = canonicalTypeNode(context, value.type_id).result;
                    const widen_ordinal = try tryErrorWidenOrdinal(context, path, program, return_result.err, value_result.err, firstExprToken(expr));
                    if (return_result.err != value_result.err and widen_ordinal == null and
                        !try tryErrorUnionWidenAllowed(context, path, program, return_result.err, value_result.err))
                    {
                        const expected_error = try formatCanonicalTypeDisplay(context, return_result.err);
                        defer context.allocator.free(expected_error);
                        const actual_error = try formatCanonicalTypeDisplay(context, value_result.err);
                        defer context.allocator.free(actual_error);
                        const notes = [_][]const u8{"the propagated error type must match the function result error type or be one of its enum union members"};
                        try context.diagnostic_context.emitTokenWith(path, firstExprToken(expr), .{
                            .code = .type_mismatch,
                            .notes = &notes,
                            .help = "add the enum to the function result error union or convert the error",
                        }, "`try` error type mismatch: expected {s}, got {s}", .{ expected_error, actual_error });
                        return SemaError.SemanticFailed;
                    }
                    if (!canonicalTypeIsVoidLike(context, value_result.ok)) {
                        try context.diagnostic_context.emitToken(path, firstExprToken(expr), "`try` statement requires a result with void success", .{});
                        return SemaError.SemanticFailed;
                    }
                    if (widen_ordinal) |ordinal| {
                        var metadata = semanticExprMetadata(context, value.expr) orelse return error.SemanticFailed;
                        metadata.try_widen_ordinal = ordinal;
                        try recordExprMetadata(context, value.expr, metadata);
                    }
                    return .{ .@"try" = .{ .expr = value.expr, .site_line = @intCast(firstExprToken(expr).line) } };
                },
                .@"defer" => |expr| {
                    const before_registration = try snapshotLocalState(allocator, locals.items);
                    defer allocator.free(before_registration);
                    const value = try lowerExpr(context, allocator, path, program, current_module, globals, locals.items, expr, try canonicalPrimitiveTypeId(context, .void));
                    errdefer value.expr.destroy(allocator);
                    try expectType(context, path, firstExprToken(expr), try canonicalPrimitiveTypeId(context, .void), value.type_id);
                    for (locals.items, before_registration) |*local, before| {
                        if (local.is_unavailable and !before.is_unavailable) {
                            local.deferred_handoff_depth = context.function_state.block_depth;
                            local.deferred_handoff_at = local.unavailable_at;
                            local.is_unavailable = false;
                            local.unavailable_at = before.unavailable_at;
                        }
                    }
                    return .{ .@"defer" = value.expr };
                },
                .drop => |drop| {
                    const index = findLocalIndex(locals.items, drop.name) orelse {
                        try context.diagnostic_context.emitToken(path, drop.name_token, "unknown local `{s}`", .{drop.name});
                        return SemaError.SemanticFailed;
                    };
                    if (locals.items[index].is_failure_view) {
                        try context.diagnostic_context.emitToken(path, drop.name_token, "cannot drop a failure view", .{});
                        return SemaError.SemanticFailed;
                    }
                    if (locals.items[index].deferred_handoff_depth != null) {
                        try context.diagnostic_context.emitToken(path, drop.name_token, "local `{s}` is reserved for a deferred handoff", .{drop.name});
                        return SemaError.SemanticFailed;
                    }
                    if (locals.items[index].is_unavailable) {
                        try emitUnavailableLocal(context, path, drop.name_token, locals.items[index], true);
                        return SemaError.SemanticFailed;
                    }
                    if (locals.items[index].binding_mode == .projected) {
                        try context.diagnostic_context.emitToken(path, drop.name_token, "cannot drop projected local `{s}`; its owner retains cleanup responsibility", .{drop.name});
                        return SemaError.SemanticFailed;
                    }
                    const drop_type = try locals.items[index].canonicalTypeId(context);
                    // A binder's storage lifetime is unknown at its definition site; the
                    // specialization that substitutes a concrete type checks it again.
                    if (!isDefinitionSiteBinder(context, drop_type) and
                        !try typeHasStorageLifetime(context, path, program, drop_type) and
                        !try typeIsOwnedValue(context, path, program, drop_type))
                    {
                        try context.diagnostic_context.emitToken(path, drop.name_token, "`drop` requires an owned value", .{});
                        return SemaError.SemanticFailed;
                    }
                    try rejectLiveBorrowInvalidation(context, path, locals.items, drop.name, drop.name_token, "drop");
                    locals.items[index].is_unavailable = true;
                    locals.items[index].unavailable_at = drop.name_token;
                    const binding_id = locals.items[index].binding_id orelse return error.SemanticFailed;
                    const record: sir.Record = .{ .effect = .{ .drop = .{ .place = .{
                        .root = .{ .binding = binding_id },
                        .projections = null,
                        .non_owning = false,
                    } } } };
                    record.validate() catch return error.SemanticFailed;
                    return .{ .drop = .{ .name = drop.name, .binding_id = binding_id, .checked_effect = record } };
                },
                .expr => |expr| {
                    const value = try lowerExpr(context, allocator, path, program, current_module, globals, locals.items, expr, null);
                    errdefer value.expr.destroy(allocator);
                    try expectType(context, path, firstExprToken(expr), try canonicalPrimitiveTypeId(context, .void), value.type_id);
                    return .{ .expr = value.expr };
                },
                .@"return" => |ret| {
                    if (ret.is_throw and canonicalTypeKind(context, return_type) != .result) {
                        try context.diagnostic_context.emitToken(path, ret.token, "`throw` requires a result return type", .{});
                        return SemaError.SemanticFailed;
                    }
                    if (ret.value == null) {
                        if (canonicalTypeNode(context, return_type).* == .result) {
                            const result = canonicalTypeNode(context, return_type).result;
                            if (canonicalTypeIsVoidLike(context, result.ok)) {
                                const success = try allocator.create(sir.Expr);
                                success.* = .{ .union_case = .{
                                    .union_name = language_contracts.result_type_name,
                                    .case_name = sir.ResultCase.ok.sourceName(),
                                    .result_case = .ok,
                                    .value = null,
                                    .result_ok_type_id = result.ok,
                                    .result_err_type_id = result.err,
                                } };
                                errdefer success.destroy(allocator);
                                var typed = makeTypedExprFromId(success, return_type);
                                try finalizeAndRecordExprSemantics(context, path, program, current_module, &typed);
                                try recordExprSink(context, success, .@"return");
                                return .{ .@"return" = success };
                            }
                        }
                        try expectTypeFrom(context, path, ret.token, try canonicalPrimitiveTypeId(context, .void), return_type, .{
                            .path = context.function_state.expected_return_path orelse path,
                            .token = context.function_state.expected_return_token orelse ret.token,
                            .message = "function return type declared here",
                        });
                        return .{ .@"return" = null };
                    }
                    const expr = ret.value.?;
                    const saved_expectation_origin = context.function_state.expected_type_origin;
                    context.function_state.expected_type_origin = .{
                        .path = context.function_state.expected_return_path orelse path,
                        .token = context.function_state.expected_return_token orelse ret.token,
                        .message = "function return type declared here",
                    };
                    defer context.function_state.expected_type_origin = saved_expectation_origin;
                    const result_return = if (canonicalTypeKind(context, return_type) == .result) canonicalTypeNode(context, return_type).result else null;
                    const success_case_context = if (result_return) |result| blk: {
                        if (expr.* != .union_case or expr.union_case.is_synthetic_throw) break :blk false;
                        var payload_type = result.ok;
                        if (canonicalTypeNode(context, payload_type).* == .optional)
                            payload_type = canonicalTypeNode(context, payload_type).optional;
                        const payload_kind = canonicalTypeKind(context, payload_type);
                        break :blk payload_kind == .@"union" or payload_kind == .@"enum";
                    } else false;
                    // Alias names need carrier context for a success payload, while
                    // complete result values must remain eligible for forwarding.
                    const alias_success_context = if (result_return) |result| blk: {
                        if (canonicalTypeKind(context, result.ok) != .ref or expr.* != .name) break :blk false;
                        const local = findLocal(locals.items, expr.name.text) orelse break :blk false;
                        break :blk local.kind(context) == .ref and
                            !type_resolution.compatible(canonicalTypeInterner(context), return_type, canonicalRefTarget(context, local.type_id));
                    } else false;
                    var value = if (alias_success_context)
                        try lowerExprInContext(context, allocator, path, program, current_module, globals, locals.items, expr, result_return.?.ok)
                    else if (result_return != null and expr.* != .union_case)
                        try lowerExpr(context, allocator, path, program, current_module, globals, locals.items, expr, result_return.?.ok)
                    else
                        try lowerExprInContext(context, allocator, path, program, current_module, globals, locals.items, expr, if (success_case_context) result_return.?.ok else return_type);
                    errdefer value.expr.destroy(allocator);
                    var wrapped_success = false;
                    if (result_return) |result| {
                        const optional_success = canonicalTypeNode(context, result.ok).* == .optional and
                            type_resolution.compatible(canonicalTypeInterner(context), result.ok, value.type_id);
                        if (value.type_id == result.ok or optional_success) {
                            try rejectProjectedResourceTransferForTypedValue(context, path, program, firstExprToken(expr), value, result.ok, "return");
                            try lowerImplicitHandoff(context, path, program, locals.items, expr, result.ok, value.expr);
                            try markCheckedNamedHandoff(context, path, program, locals.items, expr, value.expr, result.ok);
                            const wrapper = try allocator.create(sir.Expr);
                            wrapper.* = .{ .union_case = .{
                                .union_name = language_contracts.result_type_name,
                                .case_name = sir.ResultCase.ok.sourceName(),
                                .result_case = .ok,
                                .value = value.expr,
                                .result_ok_type_id = result.ok,
                                .result_err_type_id = result.err,
                            } };
                            value = makeTypedExprFromIdWithProvenance(wrapper, return_type, value.provenance);
                            value.generic_shape = try shapeFromCanonicalType(context, return_type, false);
                            try finalizeAndRecordExprSemantics(context, path, program, current_module, &value);
                            wrapped_success = true;
                        }
                    }
                    // A placeholder return type is settled by the body's own returns, so
                    // the definition site checks the join those returns produce.
                    if (!returnTypeIsDeferredPlaceholder(context, return_type))
                        try expectTypeFrom(context, path, firstExprToken(expr), return_type, value.type_id, .{
                            .path = context.function_state.expected_return_path orelse path,
                            .token = context.function_state.expected_return_token orelse ret.token,
                            .message = "function return type declared here",
                        });
                    try rejectBorrowedProvenanceReturnEscape(context, path, program, current_module, locals.items, firstExprToken(expr), value, return_type);
                    if (context.function_state.scoped_alloc_depth > 0 and canonicalTypeKind(context, return_type) != .raw and try exprCarriesScopedAllocAs(context, path, program, locals.items, expr, return_type)) {
                        try emitScopedAllocEscape(context, path, firstExprToken(expr), null, "return");
                        return SemaError.SemanticFailed;
                    }
                    if (!wrapped_success) {
                        try rejectProjectedResourceTransferForTypedValue(context, path, program, firstExprToken(expr), value, return_type, "return");
                        try lowerImplicitHandoff(context, path, program, locals.items, expr, return_type, value.expr);
                    }
                    if (context.function_state.deferred_return_join) |joined| {
                        context.function_state.deferred_return_join = try genericShapeJoinReturns(context, joined, value.generic_shape);
                    }
                    try recordExprSink(context, value.expr, .@"return");
                    if (!wrapped_success) try markCheckedNamedHandoff(context, path, program, locals.items, expr, value.expr, return_type);
                    return .{ .@"return" = value.expr };
                },
            }
        }

        pub fn lowerTakePlacePath(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            take_expr: *ast.Expr,
        ) SemaError!LoweredTakePlace {
            var reversed_steps: std.ArrayListUnmanaged(TakeAstStep) = .empty;
            defer reversed_steps.deinit(allocator);
            const object_name = try collectPlaceRootAndSteps(context, allocator, path, take_expr, &reversed_steps, "`take` requires a mutable local root place");
            const place = resolvePlace(context, program, current_module, globals, locals, take_expr) orelse {
                try context.diagnostic_context.emitToken(path, firstExprToken(take_expr), "`take` requires a mutable local root place", .{});
                return SemaError.SemanticFailed;
            };
            const local = findLocal(locals, object_name.text) orelse return SemaError.SemanticFailed;
            try rejectLiveBorrowPlaceMutationConflict(context, path, program, current_module, globals, locals, take_expr, .none, object_name.text, object_name.token, "take from");
            if (!place.access.allowsMutation()) {
                if (place.root_kind == .raw_pointee) {
                    try context.diagnostic_context.emitToken(path, firstExprToken(take_expr), "cannot take through a read-only raw pointer", .{});
                    return SemaError.SemanticFailed;
                }
                // Preserve the established root-specific diagnostics while the access
                // decision itself comes from the canonical place resolution.
                var root_expr: ast.Expr = .{ .name = object_name };
                try expectMutableReceiver(context, path, program, current_module, globals, locals, &root_expr, local.type_id, "place");
                unreachable;
            }

            var current_type = if (local.kind(context) == .ref) canonicalRefTarget(context, local.type_id) else local.type_id;
            var sir_steps: std.ArrayListUnmanaged(sir.TakePathStep) = .empty;
            var sparse_final_index: ?*sir.Expr = null;
            errdefer {
                if (sparse_final_index) |index| index.destroy(allocator);
                for (sir_steps.items) |step| switch (step) {
                    .field => {},
                    .index => |index| index.destroy(allocator),
                };
                sir_steps.deinit(allocator);
            }

            for (0..reversed_steps.items.len) |offset| {
                const step = reversed_steps.items[reversed_steps.items.len - 1 - offset];
                switch (step) {
                    .field => |field| {
                        const resolved = typeStructField(context, path, program, current_module, current_type, field.field, field.field_token) catch |err| switch (err) {
                            SemaError.SemanticFailed => {
                                try context.diagnostic_context.emitToken(path, field.field_token, "`take` field path must stay within struct values", .{});
                                return SemaError.SemanticFailed;
                            },
                            else => return err,
                        };
                        current_type = resolved.field_type_id;
                        try sir_steps.append(allocator, .{ .field = .{
                            .struct_decl_id = resolved.struct_decl_id,
                            .struct_name = resolved.struct_name,
                            .field = field.field,
                        } });
                    },
                    .index => |index| {
                        switch (canonicalTypeKind(context, current_type)) {
                            .array, .dense_array, .sparse_array => {},
                            .slice => {
                                try context.diagnostic_context.emitTokenWith(path, index.token, .{
                                    .code = .container_operation,
                                    .notes = &.{"dense and library-container indexes do not have an empty source state"},
                                    .help = "use `take` on an optional place or sparse-array slot; otherwise copy or borrow the element",
                                }, "`take` requires an optional place or sparse-array slot", .{});
                                return SemaError.SemanticFailed;
                            },
                            else => {
                                try context.diagnostic_context.emitToken(path, index.token, "`take` index path requires an array or `[:]` array", .{});
                                return SemaError.SemanticFailed;
                            },
                        }
                        const lowered_step_index = try lowerExpr(context, allocator, path, program, current_module, globals, locals, index.index, try canonicalInferredIntegerTypeId(context));
                        errdefer lowered_step_index.expr.destroy(allocator);
                        try expectType(context, path, firstExprToken(index.index), try canonicalInferredIntegerTypeId(context), lowered_step_index.type_id);
                        current_type = switch (canonicalTypeNode(context, current_type).*) {
                            .array => |array| array.item,
                            .dense_array => |item| item,
                            .sparse_array => |item| blk: {
                                if (offset + 1 != reversed_steps.items.len) {
                                    try context.diagnostic_context.emitToken(path, index.token, "`take` through sparse indexing must end at the slot itself", .{});
                                    return SemaError.SemanticFailed;
                                }
                                sparse_final_index = lowered_step_index.expr;
                                break :blk try canonicalOptionalTypeId(context, item);
                            },
                            else => unreachable,
                        };
                        if (sparse_final_index == null) {
                            try sir_steps.append(allocator, .{ .index = lowered_step_index.expr });
                        }
                    },
                }
            }

            if (canonicalTypeKind(context, current_type) != .optional) {
                try context.diagnostic_context.emitToken(path, firstExprToken(take_expr), "`take` requires a writable optional place of type `?T`", .{});
                return SemaError.SemanticFailed;
            }

            return .{
                .local_name = object_name.text,
                .type_id = current_type,
                .steps = try sir_steps.toOwnedSlice(allocator),
                .sparse_final_index = sparse_final_index,
            };
        }

        pub fn lowerTakeIndexLocal(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            expr: *ast.Expr,
            expected_type_id: ?semantic_types.TypeId,
        ) SemaError!?TypedExpr {
            if (expr.* != .unary or expr.unary.op != .take) return null;
            const take_expr = expr.unary.expr;
            var lowered_place = try lowerTakePlacePath(context, allocator, path, program, current_module, globals, locals, take_expr);
            if (expected_type_id) |expected| {
                if (expected != lowered_place.type_id) {
                    lowered_place.deinit(allocator);
                    return null;
                }
            }
            if (lowered_place.sparse_final_index) |final_index| {
                // The step array and its index expressions move into the built chain;
                // until that succeeds this scope still owns them.
                const steps = lowered_place.steps;
                lowered_place.steps = &.{};
                lowered_place.sparse_final_index = null;
                errdefer {
                    allocator.free(steps);
                    final_index.destroy(allocator);
                }
                const object = try buildTakeObjectExprFromPath(context, allocator, path, program, current_module, locals, lowered_place.local_name, steps);
                // The step index expressions moved into the built chain; only the slice
                // itself is still owned by this scope.
                allocator.free(steps);
                out.* = .{ .sparse_take = .{
                    .object = object,
                    .index = final_index,
                } };
                return withIntrinsic(makeTypedExprFromId(out, lowered_place.type_id), .sparse_take);
            }
            defer lowered_place.deinit(allocator);
            if (lowered_place.steps.len == 1) switch (lowered_place.steps[0]) {
                .index => |final_index| {
                    out.* = .{ .take_index_local = .{
                        .local_name = lowered_place.local_name,
                        .index = final_index,
                    } };
                    allocator.free(lowered_place.steps);
                    lowered_place.steps = &.{};
                },
                .field => {
                    out.* = .{ .take_path_local = .{
                        .local_name = lowered_place.local_name,
                        .steps = lowered_place.steps,
                    } };
                    lowered_place.steps = &.{};
                },
            } else if (lowered_place.steps.len != 0) switch (lowered_place.steps[lowered_place.steps.len - 1]) {
                .index => {
                    var owned_steps = lowered_place.steps;
                    const final_index = owned_steps[owned_steps.len - 1].index;
                    const prefix_steps = try allocator.alloc(sir.TakePathStep, owned_steps.len - 1);
                    @memcpy(prefix_steps, owned_steps[0 .. owned_steps.len - 1]);
                    allocator.free(owned_steps);
                    out.* = .{ .take_index_path_local = .{
                        .local_name = lowered_place.local_name,
                        .steps = prefix_steps,
                        .index = final_index,
                    } };
                    lowered_place.steps = &.{};
                },
                .field => {
                    out.* = .{ .take_path_local = .{
                        .local_name = lowered_place.local_name,
                        .steps = lowered_place.steps,
                    } };
                    lowered_place.steps = &.{};
                },
            } else {
                out.* = .{ .take_path_local = .{
                    .local_name = lowered_place.local_name,
                    .steps = lowered_place.steps,
                } };
                lowered_place.steps = &.{};
            }
            return makeTypedExprFromId(out, lowered_place.type_id);
        }

        fn constantIntegerBinary(op: ast.BinaryOp, lhs: i128, rhs: i128) ?i128 {
            return switch (op) {
                .add => std.math.add(i128, lhs, rhs) catch null,
                .sub => std.math.sub(i128, lhs, rhs) catch null,
                .mul => std.math.mul(i128, lhs, rhs) catch null,
                .div => if (rhs != 0 and !(lhs == std.math.minInt(i128) and rhs == -1)) @divTrunc(lhs, rhs) else null,
                .mod => if (rhs != 0 and !(lhs == std.math.minInt(i128) and rhs == -1)) @rem(lhs, rhs) else null,
                .bit_and => lhs & rhs,
                .bit_or => lhs | rhs,
                .bit_xor => lhs ^ rhs,
                else => null,
            };
        }

        fn constantIntegerSir(globals: []const GlobalBinding, expr: *const sir.Expr, depth: usize) ?i128 {
            if (depth > 32) return null;
            return switch (expr.*) {
                .int => |literal| if (literal.unsigned_value) |unsigned| @as(i128, unsigned) else @as(i128, literal.value),
                .unary => |unary| blk: {
                    const value = constantIntegerSir(globals, unary.expr, depth + 1) orelse break :blk null;
                    break :blk switch (unary.op) {
                        .negate => std.math.sub(i128, 0, value) catch null,
                        else => null,
                    };
                },
                .binary => |binary| blk: {
                    const lhs = constantIntegerSir(globals, binary.left, depth + 1) orelse break :blk null;
                    const rhs = constantIntegerSir(globals, binary.right, depth + 1) orelse break :blk null;
                    break :blk constantIntegerBinary(@fromBackingInt(@intCast(@backingInt(binary.op))), lhs, rhs);
                },
                .global_ref => |global_ref| blk: {
                    for (globals) |global| {
                        if (global.is_mutable or global.owner != null) continue;
                        if (global_ref.decl_id != null and global.id != global_ref.decl_id.?) continue;
                        if (!std.mem.eql(u8, global.name, global_ref.name) or !std.mem.eql(u8, global.module_name, global_ref.module_name)) continue;
                        break :blk if (global.init) |init| constantIntegerSir(globals, init, depth + 1) else null;
                    }
                    break :blk null;
                },
                else => null,
            };
        }

        fn constantIntegerAst(globals: []const GlobalBinding, current_module: []const u8, locals: []const LocalBinding, expr: *ast.Expr, depth: usize) ?i128 {
            if (depth > 32) return null;
            return switch (expr.*) {
                .int => |literal| if (literal.unsigned_value) |unsigned| @as(i128, unsigned) else @as(i128, literal.value),
                .name => |name| blk: {
                    if (findLocal(locals, name.text)) |local| break :blk if (local.is_mutable) null else local.constant_int_value;
                    for (globals) |global| {
                        if (global.is_mutable or global.owner != null or !std.mem.eql(u8, global.name, name.text) or !std.mem.eql(u8, global.module_name, current_module)) continue;
                        break :blk if (global.init) |init| constantIntegerSir(globals, init, depth + 1) else null;
                    }
                    break :blk null;
                },
                .unary => |unary| blk: {
                    const value = constantIntegerAst(globals, current_module, locals, unary.expr, depth + 1) orelse break :blk null;
                    break :blk switch (unary.op) {
                        .negate => std.math.sub(i128, 0, value) catch null,
                        else => null,
                    };
                },
                .binary => |binary| blk: {
                    const lhs = constantIntegerAst(globals, current_module, locals, binary.left, depth + 1) orelse break :blk null;
                    const rhs = constantIntegerAst(globals, current_module, locals, binary.right, depth + 1) orelse break :blk null;
                    break :blk constantIntegerBinary(binary.op, lhs, rhs);
                },
                .@"comptime" => |comptime_expr| constantIntegerAst(globals, current_module, locals, comptime_expr.expr, depth + 1),
                else => null,
            };
        }

        fn catchSwitchNeedsPropagation(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            switch_stmt: ast.Switch,
            subject_type_id: semantic_types.TypeId,
        ) SemaError!bool {
            if (!switch_stmt.catch_propagate_unmatched or switch_stmt.has_else) return false;
            switch (canonicalTypeNode(context, subject_type_id).*) {
                .nominal => |nominal| switch (nominal.kind) {
                    .@"enum" => {
                        const decl = lookupEnumDeclById(context, program, nominal.decl_id) orelse return error.SemanticFailed;
                        for (decl.cases) |case| if (!switchCoversCase(switch_stmt.cases, decl.name, case.name)) return true;
                        return false;
                    },
                    .@"union" => {
                        const decl = lookupUnionDeclById(context, program, nominal.decl_id) orelse return error.SemanticFailed;
                        if (decl.kind != .type_union) return error.SemanticFailed;
                        for (decl.variants) |variant| {
                            if (!(try switchCoversTypeUnionVariant(context, path, program, current_module, switch_stmt.cases, decl, variant))) return true;
                        }
                        return false;
                    },
                    else => return error.SemanticFailed,
                },
                .error_union => |members| {
                    for (members) |member| {
                        var covered = false;
                        for (switch_stmt.cases) |case| if (case.type_variant) |variant| {
                            if (try parseType(context, path, program, current_module, variant) == member) covered = true;
                        };
                        if (!covered) return true;
                    }
                    return false;
                },
                else => return error.SemanticFailed,
            }
        }

        fn catchPropagationCase(
            allocator: std.mem.Allocator,
            token: lexer.Token,
            enum_name: []const u8,
            case_name: ?[]const u8,
        ) SemaError!ast.SwitchCase {
            const union_variant = case_name == null;
            const type_variant: ?ast.TypeName = if (union_variant) .{
                .name = enum_name,
                .args = try allocator.alloc(ast.TypeName, 0),
                .token = token,
            } else null;
            errdefer if (type_variant) |variant| variant.deinit(allocator);
            const code = try allocator.create(ast.Expr);
            code.* = .{ .name = .{ .text = if (union_variant) "__cyna_catch_missing" else "__cyna_catch_err", .token = token } };
            var owns_code = true;
            errdefer if (owns_code) code.destroy(allocator);
            const wrapped = try allocator.create(ast.Expr);
            wrapped.* = .{ .union_case = .{ .case_name = "err", .value = code, .token = token } };
            owns_code = false;
            errdefer wrapped.destroy(allocator);
            const body = try allocator.alloc(ast.Stmt, 1);
            body[0] = .{ .@"return" = .{ .token = token, .value = wrapped } };
            return .{
                .type_name = if (union_variant) null else enum_name,
                .case_name = case_name orelse enum_name,
                .type_variant = type_variant,
                .payload_name = if (union_variant) "__cyna_catch_missing" else null,
                .token = token,
                .body = body,
            };
        }

        // Keep `switch code { First.bad => ... }` as ordinary switch syntax.
        // Lower the hidden enum union tag first, then the selected enum case.
        fn lowerErrorUnionEnumCaseSwitch(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            return_type: semantic_types.TypeId,
            locals: *std.ArrayListUnmanaged(LocalBinding),
            original: ast.Switch,
            value_type: semantic_types.TypeId,
            expression_target: ?*@TypeOf(context.function_state).SwitchYieldContext,
        ) SemaError!?sir.Stmt {
            var has_enum_cases = false;
            for (original.cases) |case| if (case.type_name != null) {
                has_enum_cases = true;
            };
            if (!has_enum_cases) return null;

            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();
            const scratch = arena_state.allocator();
            const members: []const semantic_types.TypeId = switch (canonicalTypeNode(context, value_type).*) {
                .error_union => |items| items,
                .nominal => |nominal| blk: {
                    if (nominal.kind != .@"union") return null;
                    const decl = lookupUnionDeclById(context, program, nominal.decl_id) orelse return error.SemanticFailed;
                    if (decl.kind != .type_union) return null;
                    const items = try scratch.alloc(semantic_types.TypeId, decl.variants.len);
                    for (decl.variants, 0..) |variant, index| {
                        items[index] = try parseType(context, path, program, decl.module_name, variant);
                    }
                    break :blk items;
                },
                else => return null,
            };
            const token = firstExprToken(original.value);
            const outer_cases = try scratch.alloc(ast.SwitchCase, members.len);
            for (members, 0..) |member, member_index| {
                const enum_id = canonicalNominalDeclId(context, member) orelse return error.SemanticFailed;
                const enum_decl = lookupEnumDeclById(context, program, enum_id) orelse return error.SemanticFailed;
                var matching: std.ArrayListUnmanaged(ast.SwitchCase) = .empty;
                for (original.cases) |case| {
                    if (case.type_name != null and std.mem.eql(u8, case.type_name.?, enum_decl.name)) {
                        if (case.payload_name != null or case.type_variant != null) {
                            try context.diagnostic_context.emitToken(path, case.token, "error code cases cannot bind payloads", .{});
                            return error.SemanticFailed;
                        }
                        try matching.append(scratch, case);
                    }
                }
                const payload_name = "__cyna_catch_enum_code";
                const inner_value = try scratch.create(ast.Expr);
                inner_value.* = .{ .name = .{ .text = payload_name, .token = token } };
                const inner_switch: ast.Switch = .{
                    .value = inner_value,
                    .cases = try matching.toOwnedSlice(scratch),
                    .has_else = original.has_else,
                    .else_body = original.else_body,
                };
                const body = try scratch.alloc(ast.Stmt, 1);
                if (expression_target != null) {
                    const inner_expr = try scratch.create(ast.Expr);
                    inner_expr.* = .{ .@"switch" = inner_switch };
                    body[0] = .{ .yield = .{ .token = token, .value = inner_expr } };
                } else {
                    body[0] = .{ .@"switch" = inner_switch };
                }
                outer_cases[member_index] = .{
                    .type_name = null,
                    .case_name = enum_decl.name,
                    .type_variant = .{ .name = enum_decl.name, .args = &.{}, .token = token },
                    .payload_name = payload_name,
                    .token = token,
                    .body = body,
                };
            }
            for (original.cases) |case| {
                var found = false;
                for (outer_cases) |outer_case| {
                    if (case.type_name != null and std.mem.eql(u8, case.type_name.?, outer_case.case_name)) found = true;
                }
                if (!found) {
                    try context.diagnostic_context.emitToken(path, case.token, "enum case type is not a member of this error union", .{});
                    return error.SemanticFailed;
                }
            }
            const outer: ast.Switch = .{
                .value = original.value,
                .cases = outer_cases,
                .has_else = false,
                .else_body = &.{},
            };
            return try lowerSwitch(context, allocator, path, program, current_module, globals, return_type, locals, outer, expression_target);
        }

        pub fn lowerSwitch(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            return_type: semantic_types.TypeId,
            locals: *std.ArrayListUnmanaged(LocalBinding),
            original_switch: ast.Switch,
            expression_target: ?*@TypeOf(context.function_state).SwitchYieldContext,
        ) SemaError!sir.Stmt {
            var switch_stmt = original_switch;
            const catch_scope_start = locals.items.len;
            const value = try lowerExpr(context, allocator, path, program, current_module, globals, locals.items, switch_stmt.value, null);
            var owns_value_expr = true;
            errdefer if (owns_value_expr) value.expr.destroy(allocator);
            var failure_binding_id: ?identity.BindingId = null;
            if (switch_stmt.catch_failure_name) |failure_name| {
                // Semantic sentinel only: a failure view has no emitted local value.
                var view = try localBinding(context, failure_name, try canonicalPrimitiveTypeId(context, .void), false, false);
                view.is_failure_view = true;
                failure_binding_id = view.binding_id;
                try locals.append(allocator, view);
            }
            defer locals.items.len = catch_scope_start;
            if (try lowerErrorUnionEnumCaseSwitch(context, allocator, path, program, current_module, globals, return_type, locals, switch_stmt, value.type_id, expression_target)) |lowered| {
                value.expr.destroy(allocator);
                owns_value_expr = false;
                return lowered;
            }
            var generated_cases: std.ArrayListUnmanaged(ast.SwitchCase) = .empty;
            defer {
                for (generated_cases.items) |case| case.deinit(allocator);
                generated_cases.deinit(allocator);
            }
            var combined_cases: ?[]ast.SwitchCase = null;
            defer if (combined_cases) |cases| allocator.free(cases);
            if (try catchSwitchNeedsPropagation(context, path, program, current_module, switch_stmt, value.type_id)) {
                if (canonicalTypeNode(context, return_type).* != .result) {
                    try context.diagnostic_context.emitToken(path, firstExprToken(switch_stmt.value), "partial `catch` requires an enclosing result return type", .{});
                    return error.SemanticFailed;
                }
                const token = firstExprToken(switch_stmt.value);
                switch (canonicalTypeNode(context, value.type_id).*) {
                    .nominal => |nominal| switch (nominal.kind) {
                        .@"enum" => {
                            const decl = lookupEnumDeclById(context, program, nominal.decl_id) orelse return error.SemanticFailed;
                            for (decl.cases) |case| {
                                if (switchCoversCase(switch_stmt.cases, decl.name, case.name)) continue;
                                const generated = try catchPropagationCase(allocator, token, decl.name, case.name);
                                errdefer generated.deinit(allocator);
                                try generated_cases.append(allocator, generated);
                            }
                        },
                        .@"union" => {
                            const decl = lookupUnionDeclById(context, program, nominal.decl_id) orelse return error.SemanticFailed;
                            if (decl.kind != .type_union) return error.SemanticFailed;
                            for (decl.variants) |variant| {
                                if (try switchCoversTypeUnionVariant(context, path, program, current_module, switch_stmt.cases, decl, variant)) continue;
                                const type_id = try parseType(context, path, program, decl.module_name, variant);
                                const enum_id = canonicalNominalDeclId(context, type_id) orelse return error.SemanticFailed;
                                const enum_decl = lookupEnumDeclById(context, program, enum_id) orelse return error.SemanticFailed;
                                const generated = try catchPropagationCase(allocator, token, enum_decl.name, null);
                                errdefer generated.deinit(allocator);
                                try generated_cases.append(allocator, generated);
                            }
                        },
                        else => return error.SemanticFailed,
                    },
                    .error_union => |members| for (members) |member| {
                        var covered = false;
                        for (switch_stmt.cases) |case| if (case.type_variant) |variant| {
                            if (try parseType(context, path, program, current_module, variant) == member) covered = true;
                        };
                        if (covered) continue;
                        const enum_id = canonicalNominalDeclId(context, member) orelse return error.SemanticFailed;
                        const enum_decl = lookupEnumDeclById(context, program, enum_id) orelse return error.SemanticFailed;
                        const generated = try catchPropagationCase(allocator, token, enum_decl.name, null);
                        errdefer generated.deinit(allocator);
                        try generated_cases.append(allocator, generated);
                    },
                    else => return error.SemanticFailed,
                }
                const cases = try allocator.alloc(ast.SwitchCase, switch_stmt.cases.len + generated_cases.items.len);
                @memcpy(cases[0..switch_stmt.cases.len], switch_stmt.cases);
                @memcpy(cases[switch_stmt.cases.len..], generated_cases.items);
                combined_cases = cases;
                switch_stmt.cases = cases;
            }
            var statement_target: @TypeOf(context.function_state).SwitchYieldContext = .{};
            const target = expression_target orelse &statement_target;
            target.scope_depth = context.function_state.block_depth;
            target.scoped_alloc_depth = context.function_state.scoped_alloc_depth;
            target.parent = context.function_state.active_switch_yield;
            context.function_state.active_switch_yield = target;
            defer context.function_state.active_switch_yield = target.parent;
            const entry_snapshot = try snapshotLocalState(allocator, locals.items);
            defer allocator.free(entry_snapshot);
            var merged_state: ?[]LocalBinding = null;
            defer if (merged_state) |snapshot| allocator.free(snapshot);
            // A binder subject has no concrete case set yet: the trial body models
            // the switch as the sequence of its branches so every branch is still
            // lowered, recorded, and admitted. Each specialization re-lowers it with
            // the substituted concrete type.
            if (isDefinitionSiteBinder(context, try value.canonicalTypeId(context))) {
                const payload_shape = try context.generic.shapes.project(allocator, value.generic_shape);
                var branch_count = switch_stmt.cases.len;
                if (switch_stmt.has_else) branch_count += 1;
                var branches = try allocator.alloc([]const ast.Stmt, branch_count);
                defer allocator.free(branches);
                for (switch_stmt.cases, 0..) |case, index| branches[index] = case.body;
                if (switch_stmt.has_else) branches[switch_stmt.cases.len] = switch_stmt.else_body;
                var deferred_body: std.ArrayListUnmanaged(sir.Stmt) = .empty;
                errdefer {
                    for (deferred_body.items) |stmt| stmt.deinit(allocator);
                    deferred_body.deinit(allocator);
                }
                for (branches, 0..) |branch, index| {
                    const payload_name = if (index < switch_stmt.cases.len) switch_stmt.cases[index].payload_name else null;
                    const lowered = try lowerSwitchBranchBody(context, allocator, path, program, current_module, globals, return_type, locals, branch, payload_name, value.type_id, value.provenance.derived(), null, payload_shape, projectedOrigin(value.generic_origin), locals.items.len);
                    errdefer {
                        for (lowered.body) |stmt| stmt.deinit(allocator);
                        allocator.free(lowered.body);
                        allocator.free(lowered.state);
                    }
                    try deferred_body.appendSlice(allocator, lowered.body);
                    allocator.free(lowered.body);
                    allocator.free(lowered.state);
                }
                value.expr.destroy(allocator);
                return .{ .unchecked = try deferred_body.toOwnedSlice(allocator) };
            }
            var cases: std.ArrayListUnmanaged(sir.SwitchCase) = .empty;
            errdefer {
                for (cases.items) |case| {
                    for (case.body) |stmt| stmt.deinit(allocator);
                    allocator.free(case.body);
                    if (case.scalar_pattern) |pattern| switch (pattern) {
                        .string => |text| allocator.free(text),
                        .int => {},
                    };
                }
                cases.deinit(allocator);
            }
            // Reserve publication slots before lowering owned branch bodies.
            try cases.ensureTotalCapacity(allocator, switch_stmt.cases.len);

            if (value.kind(context) == .int or value.kind(context) == .string) {
                const is_integer = value.kind(context) == .int;
                if (!switch_stmt.has_else) {
                    try context.diagnostic_context.emitToken(path, firstExprToken(switch_stmt.value), "integer and string switches require a final `_` arm", .{});
                    return SemaError.SemanticFailed;
                }
                for (switch_stmt.cases) |case| {
                    var scalar: sir.SwitchCase = .{ .case_name = "", .payload_name = null, .body = &.{} };
                    var owns_scalar_pattern = true;
                    errdefer if (owns_scalar_pattern) if (scalar.scalar_pattern) |pattern| switch (pattern) {
                        .string => |text| allocator.free(text),
                        .int => {},
                    };
                    if (is_integer) {
                        const pattern_value = if (case.scalar_pattern) |pattern|
                            constantIntegerAst(globals, current_module, locals.items, pattern, 0)
                        else blk: {
                            if (case.type_name != null or case.payload_name != null or case.type_variant == null) break :blk null;
                            var name_expr: ast.Expr = .{ .name = .{ .text = case.case_name, .token = case.token } };
                            break :blk constantIntegerAst(globals, current_module, locals.items, &name_expr, 0);
                        };
                        const integer = pattern_value orelse {
                            try context.diagnostic_context.emitToken(path, case.token, "integer switch pattern must be a compile-time integer constant", .{});
                            return SemaError.SemanticFailed;
                        };
                        const type_name = try canonicalIntegerLiteralTypeName(context, value.type_id) orelse "i64";
                        if (integer < std.math.minInt(i64) or integer > std.math.maxInt(u64) or
                            !intLiteralFitsType(context, if (integer > std.math.maxInt(i64)) 0 else @intCast(integer), if (integer > std.math.maxInt(i64)) @intCast(integer) else null, type_name))
                        {
                            try context.diagnostic_context.emitToken(path, case.token, "integer switch pattern does not fit subject type `{s}`", .{type_name});
                            return SemaError.SemanticFailed;
                        }
                        const bits: u64 = if (integer < 0) @bitCast(@as(i64, @intCast(integer))) else @intCast(integer);
                        scalar.scalar_pattern = .{ .int = @bitCast(bits) };
                        for (cases.items) |prior| if (prior.scalar_pattern) |seen| switch (seen) {
                            .int => |number| if (number == scalar.scalar_pattern.?.int) {
                                try context.diagnostic_context.emitToken(path, case.token, "duplicate integer switch pattern", .{});
                                return SemaError.SemanticFailed;
                            },
                            .string => {},
                        };
                    } else {
                        const pattern = case.scalar_pattern orelse {
                            try context.diagnostic_context.emitToken(path, case.token, "string switch pattern must be a string literal", .{});
                            return SemaError.SemanticFailed;
                        };
                        if (pattern.* != .string) {
                            try context.diagnostic_context.emitToken(path, case.token, "string switch pattern must be a string literal", .{});
                            return SemaError.SemanticFailed;
                        }
                        const text = pattern.string.text;
                        for (cases.items) |prior| if (prior.scalar_pattern) |seen| switch (seen) {
                            .string => |other| if (std.mem.eql(u8, text, other)) {
                                try context.diagnostic_context.emitToken(path, case.token, "duplicate string switch pattern", .{});
                                return SemaError.SemanticFailed;
                            },
                            .int => {},
                        };
                        const copied = try allocator.dupe(u8, text);
                        scalar.scalar_pattern = .{ .string = copied };
                    }
                    const lowered = try lowerJoinedSwitchBody(context, allocator, path, program, current_module, globals, return_type, locals, case.body, null, null, .none(), null, &generic_shapes.unknown, null, entry_snapshot, merged_state);
                    merged_state = lowered.merged;
                    scalar.body = lowered.body;
                    try cases.append(allocator, scalar);
                    owns_scalar_pattern = false;
                    allocator.free(lowered.state);
                }

                const lowered_else = try lowerJoinedSwitchBody(context, allocator, path, program, current_module, globals, return_type, locals, switch_stmt.else_body, null, null, .none(), null, &generic_shapes.unknown, null, entry_snapshot, merged_state);
                merged_state = lowered_else.merged;
                const else_body = lowered_else.body;
                allocator.free(lowered_else.state);
                errdefer {
                    for (else_body) |stmt| stmt.deinit(allocator);
                    allocator.free(else_body);
                }
                if (merged_state) |snapshot| restoreLocalState(locals.items, snapshot);
                return .{ .@"switch" = .{
                    .value = value.expr,
                    .subject_type_id = value.type_id,
                    .subject_type_name = if (is_integer) "integer" else "string",
                    .cases = try cases.toOwnedSlice(allocator),
                    .has_else = true,
                    .else_body = else_body,
                } };
            }

            if (value.kind(context) == .@"enum") {
                const enum_decl_id = canonicalNominalDeclId(context, value.type_id) orelse return error.SemanticFailed;
                const enum_decl = lookupEnumDeclById(context, program, enum_decl_id) orelse return error.SemanticFailed;
                const enum_name = enum_decl.name;

                for (switch_stmt.cases) |case| {
                    if (case.type_name) |case_type_name| {
                        if (!std.mem.eql(u8, case_type_name, enum_name)) {
                            try context.diagnostic_context.emitToken(path, case.token, "switch case type `{s}` does not match `{s}`", .{ case_type_name, enum_name });
                            return SemaError.SemanticFailed;
                        }
                    }
                    if (case.payload_name != null) {
                        try context.diagnostic_context.emitToken(path, case.token, "enum switch cases cannot bind payloads", .{});
                        return SemaError.SemanticFailed;
                    }
                    if (findEnumCase(enum_decl.cases, case.case_name) == null) {
                        try context.diagnostic_context.emitToken(path, case.token, "enum `{s}` has no case `{s}`", .{ enum_name, case.case_name });
                        return SemaError.SemanticFailed;
                    }
                    const lowered = try lowerJoinedSwitchBody(
                        context,
                        allocator,
                        path,
                        program,
                        current_module,
                        globals,
                        return_type,
                        locals,
                        case.body,
                        null,
                        null,
                        .none(),
                        null,
                        &generic_shapes.unknown,
                        null,
                        entry_snapshot,
                        merged_state,
                    );
                    merged_state = lowered.merged;
                    errdefer allocator.free(lowered.state);
                    try cases.append(allocator, .{
                        .case_name = case.case_name,
                        .payload_name = null,
                        .body = lowered.body,
                    });
                    allocator.free(lowered.state);
                }

                const lowered_else = try lowerJoinedSwitchBody(
                    context,
                    allocator,
                    path,
                    program,
                    current_module,
                    globals,
                    return_type,
                    locals,
                    switch_stmt.else_body,
                    null,
                    null,
                    .none(),
                    null,
                    &generic_shapes.unknown,
                    null,
                    entry_snapshot,
                    merged_state,
                );
                merged_state = lowered_else.merged;
                const else_body = lowered_else.body;
                allocator.free(lowered_else.state);
                errdefer {
                    for (else_body) |stmt| stmt.deinit(allocator);
                    allocator.free(else_body);
                }

                if (enum_decl.layout == .c and !switch_stmt.has_else) {
                    try context.diagnostic_context.emitToken(path, firstExprToken(switch_stmt.value), "switch over `c enum` `{s}` requires `else`", .{enum_name});
                    return SemaError.SemanticFailed;
                }

                if (!switch_stmt.has_else) {
                    for (enum_decl.cases) |enum_case| {
                        if (!switchCoversCase(switch_stmt.cases, enum_name, enum_case.name)) {
                            try context.diagnostic_context.emitToken(path, firstExprToken(switch_stmt.value), "non-exhaustive switch on `{s}`; missing `{s}.{s}`", .{ enum_name, enum_name, enum_case.name });
                            return SemaError.SemanticFailed;
                        }
                    }
                }

                if (merged_state) |snapshot| restoreLocalState(locals.items, snapshot);

                return .{ .@"switch" = .{
                    .value = value.expr,
                    .subject_type_id = value.type_id,
                    .subject_decl_id = enum_decl_id,
                    .subject_type_name = enum_name,
                    .cases = try cases.toOwnedSlice(allocator),
                    .has_else = switch_stmt.has_else,
                    .else_body = else_body,
                } };
            }

            if (value.kind(context) == .@"union") {
                const inline_members: ?[]const semantic_types.TypeId = switch (canonicalTypeNode(context, value.type_id).*) {
                    .error_union => |members| members,
                    else => null,
                };
                const union_decl_id = canonicalNominalDeclId(context, value.type_id);
                const decl = if (inline_members == null) lookupUnionDeclById(context, program, union_decl_id orelse return error.SemanticFailed) orelse return error.SemanticFailed else null;
                const union_name = if (decl) |named| named.name else "__inline_error_union";

                for (switch_stmt.cases) |case| {
                    const resolved = if (inline_members) |members|
                        try resolveInlineErrorUnionSwitchCase(context, allocator, path, program, current_module, members, case)
                    else
                        try resolveUnionSwitchCase(context, allocator, path, program, current_module, union_name, decl.?, case);
                    const lowered = try lowerJoinedSwitchBody(
                        context,
                        allocator,
                        path,
                        program,
                        current_module,
                        globals,
                        return_type,
                        locals,
                        case.body,
                        resolved.payload_name,
                        resolved.payload_type_id,
                        value.provenance.derived(),
                        switch_stmt.value,
                        try loweredCasePayloadShape(context, value.generic_shape, resolved.payload_type_id),
                        try payloadOrigin(context, resolved.payload_type_id, value),
                        entry_snapshot,
                        merged_state,
                    );
                    merged_state = lowered.merged;
                    errdefer allocator.free(lowered.state);
                    try cases.append(allocator, .{
                        .case_name = resolved.case_name,
                        .union_ordinal = if (inline_members != null) resolved.ordinal else null,
                        .payload_name = resolved.payload_name,
                        .payload_binding_id = lowered.payload_binding_id,
                        .payload_type_id = if (resolved.payload_name != null) resolved.payload_type_id else null,
                        .payload_path = if (resolved.payload_name != null) checkedCapturePath(checkedCaptureOrigin(context, value.expr), if (inline_members != null)
                            .{ .inline_error_union = .{ .type_id = value.type_id, .ordinal = resolved.ordinal } }
                        else
                            .{ .union_field = .{ .owner_decl_id = union_decl_id.?, .ordinal = resolved.ordinal } }) else null,
                        .body = lowered.body,
                    });
                    allocator.free(lowered.state);
                }

                const lowered_else = try lowerJoinedSwitchBody(
                    context,
                    allocator,
                    path,
                    program,
                    current_module,
                    globals,
                    return_type,
                    locals,
                    switch_stmt.else_body,
                    null,
                    null,
                    .none(),
                    null,
                    &generic_shapes.unknown,
                    null,
                    entry_snapshot,
                    merged_state,
                );
                merged_state = lowered_else.merged;
                const else_body = lowered_else.body;
                allocator.free(lowered_else.state);
                errdefer {
                    for (else_body) |stmt| stmt.deinit(allocator);
                    allocator.free(else_body);
                }

                if (!switch_stmt.has_else) {
                    if (inline_members) |members| {
                        for (members) |member| {
                            var covered = false;
                            for (switch_stmt.cases) |case| {
                                if (case.type_variant) |variant| {
                                    if (try parseType(context, path, program, current_module, variant) == member) covered = true;
                                }
                            }
                            if (!covered) {
                                try context.diagnostic_context.emitToken(path, firstExprToken(switch_stmt.value), "non-exhaustive switch on inline error union", .{});
                                return SemaError.SemanticFailed;
                            }
                        }
                    } else switch (decl.?.kind) {
                        .named_cases => for (decl.?.fields) |field| {
                            if (!switchCoversCase(switch_stmt.cases, null, field.name)) {
                                try context.diagnostic_context.emitToken(path, firstExprToken(switch_stmt.value), "non-exhaustive switch on `{s}`; missing `.{s}`", .{ union_name, field.name });
                                return SemaError.SemanticFailed;
                            }
                        },
                        .type_union => for (decl.?.variants) |variant| {
                            if (!(try switchCoversTypeUnionVariant(context, path, program, current_module, switch_stmt.cases, decl.?, variant))) {
                                const variant_type = try parseType(context, path, program, decl.?.module_name, variant);
                                const display = try formatTypeDisplay(context, variant_type);
                                defer allocator.free(display);
                                try context.diagnostic_context.emitToken(path, firstExprToken(switch_stmt.value), "non-exhaustive switch on `{s}`; missing `{s}`", .{ union_name, display });
                                return SemaError.SemanticFailed;
                            }
                        },
                    }
                }

                if (merged_state) |snapshot| restoreLocalState(locals.items, snapshot);

                return .{ .@"switch" = .{
                    .value = value.expr,
                    .subject_type_id = value.type_id,
                    .subject_decl_id = union_decl_id,
                    .subject_type_name = union_name,
                    .cases = try cases.toOwnedSlice(allocator),
                    .has_else = switch_stmt.has_else,
                    .else_body = else_body,
                } };
            }

            if (value.kind(context) == .result) {
                if (!switch_stmt.catch_fallback) {
                    try context.diagnostic_context.emitToken(moduleSourcePath(program, current_module, path), firstExprToken(switch_stmt.value), "switch on an error return is unavailable; use `catch (code) {{ ... }}`", .{});
                    return SemaError.SemanticFailed;
                }
                const result = canonicalTypeNode(context, value.type_id).result;
                const error_decl_id = canonicalNominalDeclId(context, result.err);
                const err_name = if (canonicalTypeNode(context, result.err).* == .error_union) "__inline_error_union" else if (error_decl_id) |decl_id| blk: {
                    if (lookupEnumDeclById(context, program, decl_id)) |decl| break :blk decl.name;
                    if (lookupUnionDeclById(context, program, decl_id)) |decl| break :blk decl.name;
                    return error.SemanticFailed;
                } else return error.SemanticFailed;
                const ok_type = result.ok;
                const err_type = result.err;
                // Catch success forwards the result's alias carrier. Inferring from
                // an uncontextualized name read would instead load its referent.
                if (target.value_required and target.result_type_id == null and canonicalTypeKind(context, ok_type) == .ref) {
                    target.result_type_id = ok_type;
                }

                var saw_ok = false;
                var saw_err = false;

                for (switch_stmt.cases) |case| {
                    if (case.type_name != null or case.type_variant != null) {
                        try context.diagnostic_context.emitToken(path, case.token, "switch on result requires `.ok` or `.err` case labels", .{});
                        return SemaError.SemanticFailed;
                    }

                    const result_case = language_contracts.resolveResultCase(case.case_name) orelse {
                        try context.diagnostic_context.emitToken(path, case.token, "result has no case `.{s}`", .{case.case_name});
                        return SemaError.SemanticFailed;
                    };
                    if (result_case == .ok) {
                        saw_ok = true;
                        const catch_void_success = switch_stmt.catch_fallback and canonicalTypeKind(context, ok_type) == .void;
                        if (case.payload_name != null and canonicalTypeKind(context, ok_type) == .void and !catch_void_success) {
                            try context.diagnostic_context.emitToken(path, case.token, "result case `.ok` does not carry a payload for result<void, E>", .{});
                            return SemaError.SemanticFailed;
                        }
                        var void_success_body = [_]ast.Stmt{.{ .yield = .{ .token = case.token, .value = null } }};
                        const case_body: []const ast.Stmt = if (catch_void_success) &void_success_body else case.body;
                        const payload_name = if (catch_void_success) null else case.payload_name;
                        const lowered = try lowerJoinedSwitchBody(
                            context,
                            allocator,
                            path,
                            program,
                            current_module,
                            globals,
                            return_type,
                            locals,
                            case_body,
                            payload_name,
                            if (payload_name != null and canonicalTypeKind(context, ok_type) != .void) ok_type else null,
                            value.provenance.derived(),
                            switch_stmt.value,
                            try loweredCasePayloadShape(context, value.generic_shape, ok_type),
                            try payloadOrigin(context, ok_type, value),
                            entry_snapshot,
                            merged_state,
                        );
                        merged_state = lowered.merged;
                        errdefer allocator.free(lowered.state);
                        try cases.append(allocator, .{
                            .case_name = case.case_name,
                            .result_case = .ok,
                            .payload_name = payload_name,
                            .payload_binding_id = lowered.payload_binding_id,
                            .payload_type_id = if (payload_name != null and canonicalTypeKind(context, ok_type) != .void) ok_type else null,
                            .payload_path = if (payload_name != null) checkedCapturePath(checkedCaptureOrigin(context, value.expr), .{ .result = .ok }) else null,
                            .body = lowered.body,
                        });
                        allocator.free(lowered.state);
                    } else {
                        saw_err = true;
                        const lowered = try lowerJoinedSwitchBody(
                            context,
                            allocator,
                            path,
                            program,
                            current_module,
                            globals,
                            return_type,
                            locals,
                            case.body,
                            case.payload_name,
                            if (case.payload_name != null) err_type else null,
                            value.provenance.derived(),
                            switch_stmt.value,
                            try loweredCasePayloadShape(context, value.generic_shape, err_type),
                            try payloadOrigin(context, err_type, value),
                            entry_snapshot,
                            merged_state,
                        );
                        merged_state = lowered.merged;
                        errdefer allocator.free(lowered.state);
                        try cases.append(allocator, .{
                            .case_name = case.case_name,
                            .result_case = .err,
                            .payload_name = case.payload_name,
                            .payload_binding_id = lowered.payload_binding_id,
                            .payload_type_id = if (case.payload_name != null) err_type else null,
                            .payload_path = if (case.payload_name != null) checkedCapturePath(checkedCaptureOrigin(context, value.expr), .{ .result = .err }) else null,
                            .body = lowered.body,
                        });
                        allocator.free(lowered.state);
                    }
                }

                const lowered_else = try lowerJoinedSwitchBody(
                    context,
                    allocator,
                    path,
                    program,
                    current_module,
                    globals,
                    return_type,
                    locals,
                    switch_stmt.else_body,
                    null,
                    null,
                    .none(),
                    null,
                    &generic_shapes.unknown,
                    null,
                    entry_snapshot,
                    merged_state,
                );
                merged_state = lowered_else.merged;
                const else_body = lowered_else.body;
                allocator.free(lowered_else.state);
                errdefer {
                    for (else_body) |stmt| stmt.deinit(allocator);
                    allocator.free(else_body);
                }

                if (!switch_stmt.has_else and (!saw_ok or !saw_err)) {
                    try context.diagnostic_context.emitToken(path, firstExprToken(switch_stmt.value), "non-exhaustive switch on result; missing `.ok` or `.err`", .{});
                    return SemaError.SemanticFailed;
                }

                if (merged_state) |snapshot| restoreLocalState(locals.items, snapshot);

                return .{ .@"switch" = .{
                    .value = value.expr,
                    .subject_type_id = value.type_id,
                    .subject_decl_id = error_decl_id,
                    .subject_type_name = err_name,
                    .catch_fallback = switch_stmt.catch_fallback,
                    .failure_binding_id = failure_binding_id,
                    .cases = try cases.toOwnedSlice(allocator),
                    .has_else = switch_stmt.has_else,
                    .else_body = else_body,
                } };
            }

            try context.diagnostic_context.emitToken(path, firstExprToken(switch_stmt.value), "switch requires an enum or union value", .{});
            return SemaError.SemanticFailed;
        }

        pub fn lowerExpr(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            expr: *ast.Expr,
            expected_type_id: ?semantic_types.TypeId,
        ) SemaError!TypedExpr {
            var lowered = try lowerExprUnfinalized(context, allocator, path, program, current_module, globals, locals, expr, expected_type_id);
            errdefer lowered.expr.destroy(allocator);
            // The lowered canonical type names the shape the expression stands for; a
            // read of a local the body joined from several binders keeps that join,
            // which no single canonical type can express.
            lowered.generic_shape = blk: {
                if (expr.* == .name) {
                    if (findLocal(locals, expr.name.text)) |local| break :blk local.generic_shape;
                }
                // The lowering records a join its canonical type cannot name (a
                // heterogeneous sequence literal, a placeholder payload); keep it.
                if (lowered.generic_shape != &generic_shapes.unknown) break :blk lowered.generic_shape;
                break :blk try shapeFromCanonicalType(context, lowered.type_id, false);
            };
            if (lowered.generic_origin == null) {
                // A binding written from a projection of a binder keeps that projection;
                // otherwise the lowered canonical type names the binder the receiver
                // stands for.
                if (expr.* == .name) {
                    if (findLocal(locals, expr.name.text)) |local| lowered.generic_origin = local.generic_origin;
                }
                if (lowered.generic_origin == null) lowered.generic_origin = receiverOriginFromType(context, lowered.type_id);
            }
            switch (expr.*) {
                // A constructor the body names is a use of the binders its type
                // arguments supply; the lowered shape already carries them.
                .struct_literal, .new_owned => |literal| if (literal.type_name != null) {
                    try recordLoweredOperationUse(context, "construct", literal.type_token, lowered);
                },
                else => {},
            }
            if (expr.* == .name) {
                if (findLocal(locals, expr.name.text)) |local| {
                    if (local.binding_mode == .projected)
                        lowered.value_semantics = .borrowedProjection();
                }
            }
            try finalizeAndRecordExprSemantics(context, path, program, current_module, &lowered);
            const source_place = if (lowered.expr.* == .failure_detail)
                null
            else
                resolvePlace(context, program, current_module, globals, locals, expr);
            const borrowed_root = if (source_place) |place| switch (canonicalTypeKind(context, place.root_type_id)) {
                .ref, .slice => true,
                else => false,
            } else false;
            var metadata = semanticExprMetadata(context, lowered.expr) orelse return error.SemanticFailed;
            const inherited_projections = metadata.checked_place_projections;
            var projections_recorded = false;
            errdefer if (!projections_recorded) {
                if (metadata.checked_place_projections) |projections| {
                    if (inherited_projections == null or projections.ptr != inherited_projections.?.ptr)
                        allocator.free(projections);
                }
            };
            metadata.non_owning_place_origin = borrowed_root or receiverTraversesAlias(context, lowered.expr);
            if (source_place) |place| {
                if (place.root_kind == .raw_pointee) {
                    if (lowered.expr.* == .raw_deref or lowered.expr.* == .ref_raw_deref) {
                        const pointer_source: ?sir.CheckedPlaceRoot = if (place.root_binding_id) |binding_id|
                            .{ .binding = binding_id }
                        else if (place.root_global_id) |global_id|
                            .{ .global = global_id }
                        else
                            null;
                        const pointee_type_id = if (lowered.expr.* == .ref_raw_deref)
                            canonicalRefTarget(context, metadata.type_id)
                        else
                            metadata.type_id;
                        if (pointer_source) |source| metadata.checked_raw_deref = .{
                            .pointer_source = source,
                            .pointee_type_id = pointee_type_id,
                            .is_volatile = if (lowered.expr.* == .raw_deref) lowered.expr.raw_deref.is_volatile else lowered.expr.ref_raw_deref.is_volatile,
                        };
                    }
                } else {
                    metadata.checked_place_root = if (place.root_binding_id) |binding_id|
                        .{ .binding = binding_id }
                    else if (place.root_global_id) |global_id|
                        .{ .global = global_id }
                    else
                        null;
                    if (metadata.checked_place_root != null) {
                        metadata.checked_place_projections = if (lowered.expr.* == .ref_path_local or lowered.expr.* == .ref_index_path_local)
                            try buildCheckedTakeProjections(context, allocator, path, program, locals, lowered.expr, metadata.type_id)
                        else
                            try buildCheckedPlaceProjections(context, allocator, lowered.expr);
                        if (metadata.checked_place_projections == null and
                            (lowered.expr.* == .field or lowered.expr.* == .borrowed_field or
                                lowered.expr.* == .index or lowered.expr.* == .borrowed_index or
                                lowered.expr.* == .union_field or lowered.expr.* == .borrowed_union_field))
                        {
                            // A hook or raw-pointee projection can produce a value
                            // without preserving the AST root as a checked place.
                            metadata.checked_place_root = null;
                        }
                    }
                }
            } else if (lowered.expr.* == .global_ref) {
                // A module-qualified global does not have an AST place root: the AST
                // root names the imported module. Its resolved declaration is the
                // checked storage identity carried by the lowered reference.
                const global_id = lowered.expr.global_ref.decl_id orelse return error.SemanticFailed;
                metadata.checked_place_root = .{ .global = global_id };
            } else if (lowered.expr.* == .slice_range) {
                if (semanticExprMetadata(context, lowered.expr.slice_range.object)) |object_metadata| {
                    if (object_metadata.checkedPlacePath()) |object_place| {
                        metadata.checked_place_root = object_place.root;
                        metadata.non_owning_place_origin = true;
                        metadata.checked_place_projections = try buildCheckedPlaceProjections(context, allocator, lowered.expr);
                    }
                }
            } else if (lowered.expr.* == .take_path_local or lowered.expr.* == .take_index_local or lowered.expr.* == .take_index_path_local or
                lowered.expr.* == .ref_path_local or lowered.expr.* == .ref_index_path_local)
            {
                // A detach consumes a projected place inside a checked binding, so the
                // lowering that cannot resolve a source place still records the binding
                // whose place the form consumes.
                const owner = switch (lowered.expr.*) {
                    .take_path_local => lowered.expr.take_path_local.local_name,
                    .take_index_local => lowered.expr.take_index_local.local_name,
                    .take_index_path_local => lowered.expr.take_index_path_local.local_name,
                    .ref_path_local => lowered.expr.ref_path_local.local_name,
                    .ref_index_path_local => lowered.expr.ref_index_path_local.local_name,
                    else => return error.SemanticFailed,
                };
                if (findLocal(locals, owner)) |local| {
                    if (local.binding_id) |binding_id| metadata.checked_place_root = .{ .binding = binding_id };
                }
                metadata.checked_place_projections = try buildCheckedTakeProjections(
                    context,
                    allocator,
                    path,
                    program,
                    locals,
                    lowered.expr,
                    metadata.type_id,
                );
            } else if (lowered.expr.* == .raw_owned_local or lowered.expr.* == .leak_owned_local) {
                // A raw or leaked handle is not itself a place, but it names the checked
                // binding whose owned place it exposes.
                const owner = if (lowered.expr.* == .raw_owned_local) lowered.expr.raw_owned_local else lowered.expr.leak_owned_local;
                if (findLocal(locals, owner)) |local| {
                    if (local.binding_id) |binding_id| metadata.checked_place_root = .{ .binding = binding_id };
                }
            }
            if (lowered.expr.* == .ref_field_expr and metadata.checked_place_projections == null) {
                // A call-produced reference reaches storage through its result, not
                // through the AST root used to invoke the hook.
                metadata.checked_place_root = null;
            }
            if (projectedRootLocal(locals, expr)) |projected| {
                const parent = projected.projected_place orelse return error.SemanticFailed;
                const prefix = parent.projections orelse return error.SemanticFailed;
                const suffix = metadata.checked_place_projections orelse &.{};
                const combined = try allocator.alloc(sir.CheckedPlaceProjection, prefix.len + suffix.len);
                @memcpy(combined[0..prefix.len], prefix);
                @memcpy(combined[prefix.len..], suffix);
                if (metadata.checked_place_projections) |old| allocator.free(old);
                metadata.checked_place_root = parent.root;
                metadata.checked_place_projections = combined;
                metadata.non_owning_place_origin = true;
            }
            try recordExprMetadata(context, lowered.expr, metadata);
            projections_recorded = true;
            if (lowered.expr.* == .leak_owned_local) {
                const checked = semanticExprMetadata(context, lowered.expr) orelse return error.SemanticFailed;
                const record = checked.checked_effect orelse return error.SemanticFailed;
                if (record.effect != .leak or record.effect.leak != .place) return error.SemanticFailed;
                const source = record.effect.leak.place;
                if (source.root != .binding or source.projections != null or source.non_owning) return error.SemanticFailed;
                const name = lowered.expr.leak_owned_local;
                const index = findLocalIndex(locals, name) orelse return error.SemanticFailed;
                if (locals[index].binding_id != source.root.binding) return error.SemanticFailed;
                try markLocalHandedOff(context, path, @constCast(locals), .{
                    .text = name,
                    .token = locals[index].declaration_token orelse expr.method_call.method_token,
                });
            }
            return lowered;
        }

        fn switchArmMayComplete(body: []const sir.Stmt) bool {
            var reachable = true;
            for (body) |stmt| {
                if (!reachable) break;
                reachable = switch (stmt) {
                    .yield, .@"return", .@"continue", .@"break" => false,
                    .expr => |expr| !sir.exprDefinitelyDiverges(expr),
                    .@"if" => |if_stmt| switchArmMayComplete(if_stmt.then_body) or switchArmMayComplete(if_stmt.else_body),
                    .unchecked => |block| switchArmMayComplete(block),
                    .using_alloc => |using_alloc| switchArmMayComplete(using_alloc.body),
                    else => true,
                };
            }
            return reachable;
        }

        pub fn lowerExprUnfinalized(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            expr: *ast.Expr,
            expected_type_id: ?semantic_types.TypeId,
        ) SemaError!TypedExpr {
            const out = try allocator.create(sir.Expr);
            // The node is neutralised before any child is attached, so an error part
            // way through lowering releases the children the node already owns.
            out.* = .none;
            errdefer out.destroy(allocator);

            switch (expr.*) {
                .@"switch" => |switch_expr| {
                    const active_locals = context.function_state.active_locals orelse {
                        try context.diagnostic_context.emitToken(path, firstExprToken(switch_expr.value), "switch expression requires a function body", .{});
                        return SemaError.SemanticFailed;
                    };
                    const function_return = context.function_state.current_return_type orelse return error.SemanticFailed;
                    var target: @TypeOf(context.function_state).SwitchYieldContext = .{
                        .expected_type_id = expected_type_id,
                        .result_type_id = expected_type_id,
                        .value_required = true,
                    };
                    const lowered = try lowerSwitch(context, allocator, path, program, current_module, globals, function_return, active_locals, switch_expr, &target);
                    if (lowered != .@"switch") {
                        lowered.deinit(allocator);
                        try context.diagnostic_context.emitToken(path, firstExprToken(switch_expr.value), "switch expression cannot use an unresolved generic subject", .{});
                        return SemaError.SemanticFailed;
                    }
                    var switch_value = lowered.@"switch";
                    const result_ty = target.result_type_id orelse try canonicalPrimitiveTypeId(context, .void);
                    switch_value.result_type_id = result_ty;
                    out.* = .{ .@"switch" = switch_value };
                    if (!canonicalTypeIsVoidLike(context, result_ty)) {
                        for (switch_value.cases) |case| {
                            if (switchArmMayComplete(case.body)) {
                                try context.diagnostic_context.emitToken(path, firstExprToken(switch_expr.value), "non-void switch arm can finish without `yield`", .{});
                                return SemaError.SemanticFailed;
                            }
                        }
                        if (switch_value.has_else and switchArmMayComplete(switch_value.else_body)) {
                            try context.diagnostic_context.emitToken(path, firstExprToken(switch_expr.value), "non-void switch arm can finish without `yield`", .{});
                            return SemaError.SemanticFailed;
                        }
                    }
                    return makeTypedExprFromIdWithProvenance(out, result_ty, target.provenance);
                },
                .float => |literal| {
                    const type_id = if (expected_type_id) |expected|
                        if (canonicalTypeNode(context, expected).* == .float)
                            expected
                        else
                            try canonicalFloatTypeId(context, "f64")
                    else
                        try canonicalFloatTypeId(context, "f64");
                    const type_name = canonicalFloatLiteralTypeName(context, type_id);
                    out.* = .{ .float = .{
                        .value = literal.value,
                        .type_name = type_name,
                    } };
                    return makeTypedExprFromId(out, type_id);
                },
                .int => |literal| {
                    const type_id = if (expected_type_id) |expected|
                        if (canonicalTypeNode(context, expected).* == .integer)
                            expected
                        else
                            try canonicalInferredIntegerTypeId(context)
                    else
                        try canonicalInferredIntegerTypeId(context);
                    const type_name = try canonicalIntegerLiteralTypeName(context, type_id);
                    if (type_name) |name| {
                        if (!intLiteralFitsType(context, literal.value, literal.unsigned_value, name)) {
                            try context.diagnostic_context.emitToken(path, literal.token, "integer literal `{s}` does not fit {s}", .{ literal.token.lexeme, name });
                            return SemaError.SemanticFailed;
                        }
                    } else if (literal.unsigned_value != null) {
                        try context.diagnostic_context.emitToken(path, literal.token, "integer literal `{s}` requires an explicit unsigned integer type", .{literal.token.lexeme});
                        return SemaError.SemanticFailed;
                    }
                    out.* = .{ .int = .{
                        .value = literal.value,
                        .unsigned_value = literal.unsigned_value,
                        .type_name = type_name,
                    } };
                    return makeTypedExprFromId(out, type_id);
                },
                .rune => |literal| {
                    if (expected_type_id) |expected| {
                        if (canonicalTypeKind(context, expected) == .int) {
                            const value: i64 = literal.value;
                            const type_name = try canonicalIntegerLiteralTypeName(context, expected);
                            if (type_name) |name| {
                                if (!intLiteralFitsType(context, value, null, name)) {
                                    try context.diagnostic_context.emitToken(path, literal.token, "rune literal `{s}` does not fit {s}", .{ literal.token.lexeme, name });
                                    return SemaError.SemanticFailed;
                                }
                            }
                            out.* = .{ .int = .{
                                .value = value,
                                .unsigned_value = null,
                                .type_name = type_name,
                            } };
                            return makeTypedExprFromId(out, expected);
                        }
                    }
                    out.* = .{ .rune = literal.value };
                    return makeTypedExprFromId(out, try canonicalPrimitiveTypeId(context, .rune));
                },
                .@"comptime" => |ct| return lowerComptimeExpr(context, path, program, current_module, out, ct),
                .string => |literal| {
                    out.* = .{ .string = literal.text };
                    return makeTypedExprFromId(out, try canonicalPrimitiveTypeId(context, .string));
                },
                .interpolated_string => |interpolated| return lowerInterpolatedString(context, allocator, path, program, current_module, globals, locals, out, interpolated),
                .bool => |literal| {
                    out.* = .{ .bool = literal.value };
                    return makeTypedExprFromId(out, try canonicalPrimitiveTypeId(context, .bool));
                },
                .function_expr => |function_expr| return lowerFunctionExpr(context, allocator, path, program, current_module, globals, locals, out, function_expr, expected_type_id),
                .none => |token| {
                    if (expected_type_id) |expected| {
                        if (canonicalTypeKind(context, expected) == .optional) {
                            out.* = .none;
                            return makeTypedExprFromId(out, expected);
                        }
                    }
                    try context.diagnostic_context.emitToken(path, token, "`none` requires an expected optional type", .{});
                    return SemaError.SemanticFailed;
                },
                .@"try" => |try_expr| return lowerTryExpr(context, allocator, path, program, current_module, globals, locals, out, try_expr, expected_type_id),
                .deref => |deref| {
                    var inner = try lowerExpr(context, allocator, path, program, current_module, globals, locals, deref.expr, null);
                    errdefer inner.expr.destroy(allocator);
                    if (isDefinitionSiteBinder(context, inner.type_id)) {
                        return try deferConcreteKindForm(context, allocator, path, program, current_module, &inner, out);
                    }
                    if (canonicalTypeNode(context, inner.type_id).* != .raw) {
                        try context.diagnostic_context.emitToken(path, deref.token, "raw pointer dereference requires a `*T` value", .{});
                        return SemaError.SemanticFailed;
                    }
                    const raw = canonicalTypeNode(context, inner.type_id).raw;
                    out.* = .{ .raw_deref = .{
                        .expr = inner.expr,
                        .is_volatile = raw.is_volatile,
                    } };
                    return makeTypedExprFromId(out, raw.target);
                },
                .enum_case => |case| return lowerEnumCase(context, path, program, current_module, out, case),
                .union_case => |case| return lowerUnionCase(context, allocator, path, program, current_module, globals, locals, out, case, expected_type_id),
                .asm_expr => |asm_expr| {
                    const target = try parseType(context, path, program, current_module, asm_expr.result_type);
                    try expectAsmResultType(context, path, asm_expr.token, target);

                    const used_inputs = try allocator.alloc(bool, asm_expr.inputs.len);
                    defer allocator.free(used_inputs);
                    @memset(used_inputs, false);
                    try validateAsmExprPlaceholders(context, path, asm_expr, used_inputs);

                    var lowered_inputs = try allocator.alloc(sir.AsmInput, asm_expr.inputs.len);
                    var lowered_input_count: usize = 0;
                    errdefer {
                        for (lowered_inputs[0..lowered_input_count]) |input| input.deinit(allocator);
                        allocator.free(lowered_inputs);
                    }
                    for (asm_expr.inputs, 0..) |input, i| {
                        const lowered = try lowerExpr(context, allocator, path, program, current_module, globals, locals, input.value, null);
                        errdefer lowered.expr.destroy(allocator);
                        try expectAsmInputType(context, path, input.name_token, try lowered.canonicalTypeId(context));
                        lowered_inputs[i] = .{
                            .name = input.name,
                            .constraint = lowerAsmConstraint(input.constraint),
                            .value = lowered.expr,
                        };
                        lowered_input_count += 1;
                    }
                    const lowered_inout = if (asm_expr.inout) |inout| blk: {
                        const lowered = try lowerExpr(context, allocator, path, program, current_module, globals, locals, inout.value, null);
                        errdefer lowered.expr.destroy(allocator);
                        try expectAsmInputType(context, path, inout.name_token, try lowered.canonicalTypeId(context));
                        try expectType(context, path, inout.name_token, target, lowered.type_id);
                        break :blk sir.AsmInput{
                            .name = inout.name,
                            .constraint = lowerAsmConstraint(inout.constraint),
                            .value = lowered.expr,
                        };
                    } else null;

                    const lines = try allocator.alloc([]const u8, asm_expr.lines.len);
                    errdefer allocator.free(lines);
                    @memcpy(lines, asm_expr.lines);
                    const clobbers = try allocator.alloc(sir.AsmClobber, asm_expr.clobbers.len);
                    var clobber_count: usize = 0;
                    errdefer {
                        for (clobbers[0..clobber_count]) |clobber| clobber.deinit(allocator);
                        allocator.free(clobbers);
                    }
                    for (asm_expr.clobbers, 0..) |clobber, i| {
                        clobbers[i] = try lowerAsmClobber(context, allocator, path, asm_expr.token, clobber);
                        clobber_count += 1;
                    }
                    out.* = .{ .asm_expr = .{
                        .target_type_id = target,
                        .lines = lines,
                        .output = if (asm_expr.output) |output| .{
                            .name = output.name,
                            .constraint = lowerAsmConstraint(output.constraint),
                        } else null,
                        .inout = lowered_inout,
                        .inputs = lowered_inputs,
                        .clobbers = clobbers,
                        .is_volatile = asm_expr.is_volatile,
                    } };
                    return try makeTypedExpr(context, out, target);
                },
                .is_test => |is_test| return lowerIsTestExpr(context, allocator, path, program, current_module, globals, locals, out, is_test),
                .cast => |cast| {
                    const lowered = try lowerCastExpr(context, allocator, path, program, current_module, globals, locals, out, cast);
                    if (context.options.literal_cast_normalizations) |normalizations| {
                        if (!cast.fallible and !cast.reinterpret and cast.target.args.len == 0 and
                            expected_type_id != null and lowered.type_id == expected_type_id.?)
                        {
                            const safe_literal = switch (cast.subject.*) {
                                .int => |literal| blk: {
                                    const name = try canonicalIntegerLiteralTypeName(context, lowered.type_id) orelse break :blk false;
                                    break :blk intLiteralFitsType(context, literal.value, literal.unsigned_value, name);
                                },
                                .float => |literal| blk: {
                                    const name = canonicalFloatLiteralTypeName(context, lowered.type_id) orelse break :blk false;
                                    if (!std.math.isFinite(literal.value)) break :blk false;
                                    const width: u16 = if (std.mem.eql(u8, name, "c_float")) 32 else if (std.mem.eql(u8, name, "c_double")) 64 else namedFloatBitWidth(name) orelse break :blk false;
                                    break :blk switch (width) {
                                        32 => @abs(literal.value) <= std.math.floatMax(f32) and
                                            @as(f64, @floatCast(@as(f32, @floatCast(literal.value)))) == literal.value,
                                        64 => true,
                                        else => false,
                                    };
                                },
                                else => false,
                            };
                            if (safe_literal) try normalizations.append(context.allocator, .{
                                .module_name = current_module,
                                .cast_offset = cast.token.offset,
                                .target_end_offset = cast.target.token.end_offset,
                            });
                        }
                    }
                    return lowered;
                },
                .address_of => |address_of| {
                    switch (address_of.expr.*) {
                        .name => |name| {
                            if (findLocal(locals, name.text)) |local| {
                                if (local.is_unavailable) {
                                    try emitUnavailableLocal(context, path, name.token, local, false);
                                    return SemaError.SemanticFailed;
                                }
                                if (local.kind(context) == .ref) {
                                    try context.diagnostic_context.emitToken(path, name.token, "cannot create an alias to another alias; borrow the original owner instead", .{});
                                    return SemaError.SemanticFailed;
                                }
                                if (local.kind(context) == .owned) {
                                    try context.diagnostic_context.emitToken(path, name.token, "cannot create alias to an owned pointer directly; pass the owned value where `&T` is expected", .{});
                                    return SemaError.SemanticFailed;
                                }
                                out.* = .{ .ref_local = name.text };
                                const place = resolvePlace(context, program, current_module, globals, locals, address_of.expr) orelse
                                    return SemaError.SemanticFailed;
                                if (place.access.allowsMutation()) {
                                    try rejectProjectedBindingMutableAliasCreation(context, path, program, current_module, globals, locals, address_of.expr, name.token);
                                }
                                return try makeTypedExprWithProvenance(
                                    context,
                                    out,
                                    try canonicalRefTypeIdForAccess(context, local.type_id, place.access),
                                    Provenance.fromNormalizedBorrowRoots(place.roots),
                                );
                            }
                            if (findGlobal(context, program, globals, current_module, name.text)) |global| {
                                try rejectIsolatedMutableGlobalAccess(context, path, name.token, global, "borrow");
                                out.* = .{ .ref_global = .{
                                    .decl_id = global.id,
                                    .module_name = global.module_name,
                                    .owner = global.owner,
                                    .name = global.name,
                                } };
                                return try makeTypedExprWithProvenance(
                                    context,
                                    out,
                                    try canonicalRefTypeIdForAccess(context, global.type_id, if (global.is_mutable) .writable else .read_only),
                                    try rootedBorrowProvenanceForType(context, path, program, global.module_name, global.type_id, .global, global.name),
                                );
                            }
                            try context.diagnostic_context.emitToken(path, name.token, "unknown local `{s}`", .{name.text});
                            return SemaError.SemanticFailed;
                        },
                        .field => |field| {
                            _ = field;
                            var take_steps: std.ArrayListUnmanaged(TakeAstStep) = .empty;
                            defer take_steps.deinit(allocator);
                            const take_root = try collectPlaceRootAndSteps(context, allocator, path, address_of.expr, &take_steps, "address-of requires an addressable place");
                            const take_local = findLocal(locals, take_root.text) orelse {
                                if (findGlobal(context, program, globals, current_module, take_root.text)) |global| {
                                    return try lowerAddressOfGlobalFieldAlias(
                                        context,
                                        allocator,
                                        path,
                                        program,
                                        current_module,
                                        out,
                                        address_of.expr,
                                        take_root,
                                        global,
                                        take_steps.items,
                                    );
                                }
                                try context.diagnostic_context.emitToken(path, take_root.token, "unknown local `{s}`", .{take_root.text});
                                return SemaError.SemanticFailed;
                            };
                            if (take_local.is_unavailable) {
                                try emitUnavailableLocal(context, path, take_root.token, take_local, false);
                                return SemaError.SemanticFailed;
                            }
                            if (try lowerAddressOfRawFieldAlias(context, allocator, path, program, current_module, globals, locals, out, address_of.expr, take_steps.items)) |alias| {
                                return alias;
                            }
                            if (try lowerHookIndexedFieldAlias(context, allocator, path, program, current_module, globals, locals, out, address_of.expr)) |alias| {
                                return alias;
                            }

                            const alias_path = try collectFieldAliasPath(context, allocator, path, address_of.expr);
                            defer allocator.free(alias_path.steps);
                            const object_name = alias_path.base;
                            const local = findLocal(locals, object_name.text) orelse {
                                try context.diagnostic_context.emitToken(path, object_name.token, "unknown local `{s}`", .{object_name.text});
                                return SemaError.SemanticFailed;
                            };
                            if (local.is_unavailable) {
                                try emitUnavailableLocal(context, path, object_name.token, local, false);
                                return SemaError.SemanticFailed;
                            }
                            const place = resolvePlace(context, program, current_module, globals, locals, address_of.expr) orelse
                                return SemaError.SemanticFailed;
                            if (place.access.allowsMutation()) {
                                try rejectProjectedBindingMutableAliasCreation(context, path, program, current_module, globals, locals, address_of.expr, address_of.token);
                            }
                            var current_type = canonicalUnwrapOwned(context, if (local.kind(context) == .ref) canonicalRefTarget(context, local.type_id) else local.type_id);
                            var first_struct_decl_id: ?identity.DeclId = null;
                            var first_struct_name: ?[]const u8 = null;
                            var first_field_name: ?[]const u8 = null;
                            var final_field_type: ?semantic_types.TypeId = null;
                            var sir_steps: []sir.TakePathStep = undefined;
                            if (alias_path.steps.len > 1) {
                                sir_steps = try allocator.alloc(sir.TakePathStep, alias_path.steps.len);
                            } else {
                                sir_steps = &.{};
                            }
                            errdefer if (alias_path.steps.len > 1) allocator.free(sir_steps);
                            for (alias_path.steps, 0..) |step, i| {
                                const resolved = try typeStructField(context, path, program, current_module, current_type, step.field, step.field_token);
                                if (resolved.decl.layout == .@"packed") {
                                    try context.diagnostic_context.emitToken(path, address_of.token, "cannot create alias to packed field `{s}` in safe code", .{step.field});
                                    return SemaError.SemanticFailed;
                                }
                                if (i == 0) {
                                    first_struct_decl_id = resolved.struct_decl_id;
                                    first_struct_name = resolved.struct_name;
                                    first_field_name = step.field;
                                }
                                final_field_type = resolved.field_type_id;
                                if (alias_path.steps.len > 1) {
                                    sir_steps[i] = .{ .field = .{
                                        .struct_decl_id = resolved.struct_decl_id,
                                        .struct_name = resolved.struct_name,
                                        .field = step.field,
                                    } };
                                }
                                current_type = resolved.field_type_id;
                            }

                            out.* = if (alias_path.steps.len > 1)
                                .{ .ref_path_local = .{
                                    .local_name = object_name.text,
                                    .steps = sir_steps,
                                } }
                            else if (local.kind(context) == .owned)
                                .{ .ref_field_owned_local = .{
                                    .local_name = object_name.text,
                                    .struct_decl_id = first_struct_decl_id,
                                    .struct_name = first_struct_name.?,
                                    .field = first_field_name.?,
                                } }
                            else
                                .{ .ref_field_local = .{
                                    .local_name = object_name.text,
                                    .struct_decl_id = first_struct_decl_id,
                                    .struct_name = first_struct_name.?,
                                    .field = first_field_name.?,
                                } };
                            return try makeTypedExprWithProvenance(
                                context,
                                out,
                                try canonicalRefTypeIdForAccess(context, final_field_type.?, place.access),
                                Provenance.fromNormalizedBorrowRoots(place.roots),
                            );
                        },
                        .index => |index| {
                            _ = index;
                            return try lowerAddressOfIndexedPlaceAlias(context, allocator, path, program, current_module, globals, locals, out, address_of.expr);
                        },
                        .deref => |deref| {
                            var inner = try lowerExpr(context, allocator, path, program, current_module, globals, locals, deref.expr, null);
                            errdefer inner.expr.destroy(allocator);
                            if (canonicalTypeNode(context, inner.type_id).* != .raw) {
                                try context.diagnostic_context.emitToken(path, deref.token, "raw pointer dereference requires a `*T` value", .{});
                                return SemaError.SemanticFailed;
                            }
                            const raw = canonicalTypeNode(context, inner.type_id).raw;
                            out.* = .{ .ref_raw_deref = .{
                                .expr = inner.expr,
                                .is_volatile = raw.is_volatile,
                            } };
                            return makeTypedExprFromId(out, try canonicalRefTypeIdForAccess(context, raw.target, if (raw.is_const) .read_only else .writable));
                        },
                        else => {
                            try context.diagnostic_context.emitToken(path, address_of.token, "address-of requires a local or field lvalue", .{});
                            return SemaError.SemanticFailed;
                        },
                    }
                },
                .name => |name| {
                    if (findLocal(locals, name.text)) |local| {
                        if (local.is_failure_view) {
                            try context.diagnostic_context.emitToken(path, name.token, "failure view cannot be used as a value", .{});
                            return SemaError.SemanticFailed;
                        }
                        if (local.is_unavailable) {
                            try emitUnavailableLocal(context, path, name.token, local, false);
                            return SemaError.SemanticFailed;
                        }
                        const local_type = if (local.kind(context) == .ref) canonicalRefTarget(context, local.type_id) else local.type_id;
                        try maybeRecordSemanticHoverFact(context, allocator, path, program, current_module, name.token, name.text, local.type_id, local.provenance);
                        out.* = .{ .local = name.text };
                        return try makeTypedExprWithProvenance(
                            context,
                            out,
                            local_type,
                            local.provenance,
                        );
                    }
                    if (context.function_state.forbidden_capture_locals) |forbidden| {
                        if (findLocal(forbidden, name.text)) |captured| {
                            if (captured.is_failure_view) {
                                try context.diagnostic_context.emitToken(path, name.token, "failure view cannot be captured", .{});
                                return SemaError.SemanticFailed;
                            }
                            if (context.function_state.arrow_capture_records) |records| {
                                if (captured.is_unavailable) {
                                    try emitUnavailableLocal(context, path, name.token, captured, false);
                                    return SemaError.SemanticFailed;
                                }
                                const field_index = try recordArrowCapture(allocator, records, captured);
                                const capture_type = if (captured.kind(context) == .ref) canonicalRefTarget(context, captured.type_id) else captured.type_id;
                                const capture_type_id = capture_type;
                                out.* = .{ .closure_capture = .{
                                    .env_name = context.function_state.arrow_capture_env_name orelse return SemaError.SemanticFailed,
                                    .env_type_name = context.function_state.arrow_capture_env_type_name orelse return SemaError.SemanticFailed,
                                    .env_decl_id = context.function_state.arrow_capture_env_decl_id orelse return SemaError.SemanticFailed,
                                    .field_index = field_index,
                                    .type_id = capture_type_id,
                                } };
                                return .{
                                    .expr = out,
                                    .type_id = capture_type_id,
                                    .provenance = captured.provenance,
                                };
                            }
                            const expression_name = if (context.function_state.forbidden_capture_is_lambda) "lambda expression" else "function expression";
                            try emitOwnershipDiagnostic(
                                context,
                                path,
                                name.token,
                                .ownership_capture,
                                captured.declaration_token,
                                "local declared outside this function expression",
                                "stored `fn(...)` callbacks are non-capturing",
                                "pass the lambda directly to a `(...) => R` parameter, or store explicit context beside the function pointer",
                                "{s} cannot capture local `{s}` as a stored `fn(...)` callback; pass the lambda directly to a `(...) => R` parameter, or store explicit context beside the function pointer",
                                .{ expression_name, name.text },
                            );
                            return SemaError.SemanticFailed;
                        }
                    }
                    if (findGlobal(context, program, globals, current_module, name.text)) |global| {
                        try rejectIsolatedMutableGlobalAccess(context, path, name.token, global, "read");
                        out.* = .{ .global_ref = .{
                            .decl_id = global.id,
                            .module_name = global.module_name,
                            .owner = global.owner,
                            .name = global.name,
                        } };
                        return try makeTypedExprWithProvenance(
                            context,
                            out,
                            global.type_id,
                            try rootedBorrowProvenanceForType(context, path, program, global.module_name, global.type_id, .global, global.name),
                        );
                    }
                    if (genericArrayLenForName(context.function_state.current_generic_params, context.function_state.current_generic_args, name.text)) |len| {
                        out.* = .{ .int = .{
                            .value = @intCast(len),
                            .unsigned_value = len,
                            .type_name = "usize",
                        } };
                        return makeTypedExprFromId(out, try canonicalIntegerTypeId(context, "usize"));
                    }
                    if (expected_type_id) |expected| {
                        const expected_node = canonicalTypeNode(context, expected).*;
                        if (expected_node == .callable) {
                            const resolved_function = findAstFunction(context, program, current_module, null, name.text) orelse {
                                try emitUnknownCallable(context, path, program, current_module, name.token, name.text);
                                return SemaError.SemanticFailed;
                            };
                            const function = resolved_function.decl;
                            if (function.type_params.len != 0) {
                                try context.diagnostic_context.emitToken(path, name.token, "generic function `{s}` cannot be used as a function value", .{name.text});
                                return SemaError.SemanticFailed;
                            }
                            const actual_type = try functionDeclType(context, allocator, path, program, function);
                            if (!type_resolution.callableSignaturesEqual(
                                expected_node,
                                canonicalTypeNode(context, actual_type).*,
                            )) {
                                const actual_display = try formatTypeDisplay(context, actual_type);
                                defer allocator.free(actual_display);
                                const expected_display = try formatCanonicalTypeDisplay(context, expected);
                                defer allocator.free(expected_display);
                                try context.diagnostic_context.emitToken(path, name.token, "function `{s}` has type `{s}`, expected `{s}`", .{
                                    name.text,
                                    actual_display,
                                    expected_display,
                                });
                                return SemaError.SemanticFailed;
                            }
                            if (expected_node.callable.kind == .arrow) {
                                const adapter_name = try synthesizeArrowCallableAdapter(context, allocator, path, program, current_module, function, expected, name.token);
                                out.* = .{ .closure = .{
                                    .function = .{
                                        .decl_id = maybeRegisteredDeclId(context, current_module, null, adapter_name, .function),
                                        .module_name = current_module,
                                        .owner = null,
                                        .name = adapter_name,
                                    },
                                    .env_type_name = "c_void",
                                    .env_decl_id = null,
                                    .captures = &.{},
                                } };
                            } else if (expected_node.callable.calling_convention == .c and
                                canonicalTypeNode(context, actual_type).callable.calling_convention == .cyna)
                            {
                                const adapter_name = try synthesizeCAbiCallableAdapter(
                                    context,
                                    allocator,
                                    path,
                                    program,
                                    current_module,
                                    function,
                                    expected,
                                    name.token,
                                );
                                out.* = .{ .function_ref = .{
                                    .decl_id = maybeRegisteredDeclId(context, current_module, null, adapter_name, .function),
                                    .module_name = current_module,
                                    .owner = null,
                                    .name = adapter_name,
                                } };
                            } else {
                                out.* = .{ .function_ref = .{
                                    .decl_id = resolved_function.id,
                                    .module_name = function.module_name,
                                    .owner = function.owner,
                                    .name = function.name,
                                } };
                            }
                            return makeTypedExprFromId(out, expected);
                        }
                    }
                    try emitUnknownValue(context, path, name.token, locals, name.text, .value);
                    return SemaError.SemanticFailed;
                },
                .unary => |unary| return lowerUnary(context, allocator, path, program, current_module, globals, locals, out, unary),
                .binary => |binary| return lowerBinary(context, allocator, path, program, current_module, globals, locals, out, binary),
                .call => |call| return lowerCall(context, allocator, path, program, current_module, globals, locals, out, call, expected_type_id),
                .method_call => |call| return lowerMethodCall(context, allocator, path, program, current_module, globals, locals, out, call),
                .new_array => |new_array| return lowerNewArray(context, allocator, path, program, current_module, globals, locals, out, new_array),
                .new_sparse => |new_sparse| return lowerNewSparse(context, allocator, path, program, current_module, globals, locals, out, new_sparse),
                .array_literal => |literal| return if (literal.token.tag == .l_paren)
                    lowerTupleLiteral(context, allocator, path, program, current_module, globals, locals, out, literal, expected_type_id)
                else
                    lowerArrayLiteral(context, allocator, path, program, current_module, globals, locals, out, literal, expected_type_id),
                .sequence_repeat => |repeat| return lowerSequenceRepeat(context, allocator, path, program, current_module, globals, locals, out, repeat, expected_type_id),
                .typed_sequence_literal => |literal| return lowerTypedSequenceLiteral(context, allocator, path, program, current_module, globals, locals, out, literal, expected_type_id),
                .keyed_literal => |literal| return lowerKeyedLiteral(context, allocator, path, program, current_module, globals, locals, out, literal, expected_type_id),
                .fixed_array_construct => |construct| return lowerFixedArrayConstruct(context, allocator, path, program, current_module, globals, locals, out, construct),
                .new_owned => |literal| return lowerOwnedStructLiteral(context, allocator, path, program, current_module, globals, locals, out, literal),
                .struct_literal => |literal| return lowerStructLiteral(context, allocator, path, program, current_module, globals, locals, out, literal, expected_type_id),
                .field => |field| return lowerFieldAccess(context, allocator, path, program, current_module, globals, locals, out, field),
                .slice_range => |slice| return lowerSliceRange(context, allocator, path, program, current_module, globals, locals, out, slice),
                .index => |index| return lowerIndex(context, allocator, path, program, current_module, globals, locals, out, index),
            }
        }

        pub fn lowerUnionCase(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            case: ast.UnionCaseExpr,
            expected_type_id: ?semantic_types.TypeId,
        ) SemaError!TypedExpr {
            if (expected_type_id) |expected| {
                if (canonicalTypeKind(context, expected) == .result) {
                    if (!case.is_synthetic_throw) {
                        try context.diagnostic_context.emitToken(path, case.token, "result cases `.{s}` are unavailable; use `return` or `throw`", .{case.case_name});
                        return SemaError.SemanticFailed;
                    }
                    const result_type = canonicalTypeNode(context, expected).result;
                    if (language_contracts.resolveResultCase(case.case_name)) |result_case| {
                        const payload = try lowerExpectedResultCasePayload(
                            context,
                            allocator,
                            path,
                            program,
                            current_module,
                            globals,
                            locals,
                            case.token,
                            expected,
                            result_case,
                            case.value,
                        );
                        out.* = .{ .union_case = .{
                            .union_name = language_contracts.result_type_name,
                            .case_name = result_case.sourceName(),
                            .result_case = result_case,
                            .from_throw = case.is_synthetic_throw,
                            .throw_message = if (case.throw_message) |message| try allocator.dupe(u8, message.text) else null,
                            .throw_source_line = if (case.is_synthetic_throw) @intCast(case.token.line) else 0,
                            .throw_local_binding_id = if (case.is_synthetic_throw and case.value != null and case.value.?.* == .name)
                                if (findLocal(locals, case.value.?.name.text)) |local| local.binding_id else null
                            else
                                null,
                            .value = payload.expr,
                            .result_ok_type_id = result_type.ok,
                            .result_err_type_id = result_type.err,
                        } };
                        return makeTypedExprFromIdWithProvenance(out, expected, payload.provenance);
                    }
                }
            }

            const union_type_id = expected_type_id orelse {
                try context.diagnostic_context.emitToken(path, case.token, "`.{s}` requires an expected union type", .{case.case_name});
                return SemaError.SemanticFailed;
            };
            if (canonicalTypeKind(context, union_type_id) != .@"union") {
                try context.diagnostic_context.emitToken(path, case.token, "`.{s}` requires an expected union type", .{case.case_name});
                return SemaError.SemanticFailed;
            }

            const union_name = canonicalNominalDeclName(context, program, union_type_id) orelse return error.SemanticFailed;
            const union_decl_id = canonicalNominalDeclId(context, union_type_id) orelse return error.SemanticFailed;
            const decl = lookupUnionDeclById(context, program, union_decl_id) orelse {
                try context.diagnostic_context.emitToken(path, case.token, "unknown union `{s}`", .{union_name});
                return SemaError.SemanticFailed;
            };
            const union_field = findUnionField(decl.fields, case.case_name) orelse {
                try context.diagnostic_context.emitToken(path, case.token, "union `{s}` has no case `{s}`", .{ union_name, case.case_name });
                return SemaError.SemanticFailed;
            };

            const payload = if (union_field.type_name) |type_name| blk: {
                const payload_expr = case.value orelse {
                    try context.diagnostic_context.emitToken(path, case.token, "union case `{s}.{s}` requires a payload", .{ union_name, case.case_name });
                    return SemaError.SemanticFailed;
                };
                const payload_type = try parseType(context, path, program, decl.module_name, type_name);
                const lowered = try lowerExprInContext(context, allocator, path, program, current_module, globals, locals, payload_expr, payload_type);
                errdefer lowered.expr.destroy(allocator);
                try expectType(context, path, firstExprToken(payload_expr), payload_type, lowered.type_id);
                try lowerImplicitHandoff(context, path, program, locals, payload_expr, payload_type, lowered.expr);
                try markCheckedNamedHandoff(context, path, program, @constCast(locals), payload_expr, lowered.expr, payload_type);
                break :blk ResultCasePayload{ .expr = lowered.expr, .provenance = lowered.provenance };
            } else blk: {
                if (case.value != null) {
                    try context.diagnostic_context.emitToken(path, case.token, "union case `{s}.{s}` does not take a payload", .{ union_name, case.case_name });
                    return SemaError.SemanticFailed;
                }
                break :blk ResultCasePayload{ .expr = null, .provenance = .none() };
            };

            out.* = .{ .union_case = .{
                .decl_id = union_decl_id,
                .union_name = union_name,
                .case_name = case.case_name,
                .value = payload.expr,
            } };
            return makeTypedExprFromIdWithProvenance(out, union_type_id, payload.provenance);
        }

        pub fn lowerIsTestExpr(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            is_test: ast.IsTestExpr,
        ) SemaError!TypedExpr {
            if (is_test.capture_name != null) {
                try context.diagnostic_context.emitToken(path, is_test.token, "`is` captures are only supported directly in `if` conditions", .{});
                return SemaError.SemanticFailed;
            }
            const subject = try lowerExpr(context, allocator, path, program, current_module, globals, locals, is_test.subject, null);
            errdefer subject.expr.destroy(allocator);

            switch (is_test.kind) {
                .optional_none => {
                    const subject_type_id = if (subject.kind(context) == .ref) canonicalRefTarget(context, subject.type_id) else subject.type_id;
                    if (canonicalTypeNode(context, subject_type_id).* != .optional) {
                        try context.diagnostic_context.emitToken(path, is_test.token, "`is none` requires an optional value", .{});
                        return SemaError.SemanticFailed;
                    }
                },
                .optional_some => {
                    const subject_type_id = if (subject.kind(context) == .ref) canonicalRefTarget(context, subject.type_id) else subject.type_id;
                    if (canonicalTypeNode(context, subject_type_id).* != .optional) {
                        try context.diagnostic_context.emitToken(path, is_test.token, "`is name` requires an optional value", .{});
                        return SemaError.SemanticFailed;
                    }
                },
                .union_case => {
                    if (subject.kind(context) != .@"union") {
                        try context.diagnostic_context.emitToken(path, is_test.token, "`is .tag` requires a union value", .{});
                        return SemaError.SemanticFailed;
                    }
                    const union_decl_id = canonicalNominalDeclId(context, subject.type_id) orelse return error.SemanticFailed;
                    const decl = lookupUnionDeclById(context, program, union_decl_id) orelse return error.SemanticFailed;
                    const union_name = decl.name;
                    if (findUnionField(decl.fields, is_test.case_name.?) == null) {
                        try context.diagnostic_context.emitToken(path, is_test.token, "union `{s}` has no case `{s}`", .{ union_name, is_test.case_name.? });
                        return SemaError.SemanticFailed;
                    }
                },
            }

            out.* = .{ .is_test = .{
                .subject = subject.expr,
                .kind = @fromBackingInt(@intCast(@backingInt(is_test.kind))),
                .case_name = is_test.case_name,
            } };
            return makeTypedExprFromId(out, try canonicalPrimitiveTypeId(context, .bool));
        }

        pub fn lowerCastExpr(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            cast: ast.CastExpr,
        ) SemaError!TypedExpr {
            const subject = try lowerExpr(context, allocator, path, program, current_module, globals, locals, cast.subject, null);
            errdefer subject.expr.destroy(allocator);
            const target = try parseCanonicalType(context, path, program, current_module, cast.target);
            const target_node = canonicalTypeNode(context, target);
            if (target_node.* == .primitive and target_node.primitive == .c_str) {
                if (cast.fallible or cast.reinterpret) {
                    try context.diagnostic_context.emitToken(path, cast.token, "`c_str` literal adaptation uses ordinary `as`, not `as?` or `as!`", .{});
                    return SemaError.SemanticFailed;
                }
                if (cast.subject.* != .string) {
                    try context.diagnostic_context.emitToken(path, cast.token, "only a static string literal can be adapted to `c_str`; use an explicit NUL-terminated C buffer for dynamic text", .{});
                    return SemaError.SemanticFailed;
                }
                if (std.mem.indexOfScalar(u8, cast.subject.string.text, 0) != null) {
                    try context.diagnostic_context.emitToken(path, cast.subject.string.token, "`c_str` literals cannot contain an embedded NUL byte", .{});
                    return SemaError.SemanticFailed;
                }
                out.* = .{ .cast = .{
                    .subject = subject.expr,
                    .target_type_id = target,
                    .union_case_name = null,
                    .fallible = false,
                    .reinterpret = false,
                } };
                return makeTypedExprFromIdWithProvenance(out, target, .staticValue());
            }
            const target_kind = canonicalTypeKind(context, target);
            const target_name = switch (target_kind) {
                .int => try canonicalIntegerLiteralTypeName(context, target),
                .float => canonicalFloatLiteralTypeName(context, target),
                .@"struct", .@"enum", .@"union" => canonicalNominalDeclName(context, program, target),
                else => null,
            };
            const subject_name = switch (subject.kind(context)) {
                .int => try canonicalIntegerLiteralTypeName(context, subject.type_id),
                .float => canonicalFloatLiteralTypeName(context, subject.type_id),
                .@"struct", .@"enum", .@"union" => canonicalNominalDeclName(context, program, subject.type_id),
                else => null,
            };
            if (cast.reinterpret) {
                if (cast.fallible) {
                    try context.diagnostic_context.emitToken(path, cast.token, "`as!` is not fallible", .{});
                    return SemaError.SemanticFailed;
                }

                if (subject.kind(context) == .@"struct" and subject_name != null) {
                    if (!try isPackedStructType(context, program, try subject.canonicalTypeId(context))) {
                        try context.diagnostic_context.emitToken(path, cast.token, "`as!` only supports packed struct/int bit reinterpretation; `{s}` is not packed", .{subject_name.?});
                        return SemaError.SemanticFailed;
                    }
                    if (target_kind != .int or target_name == null) {
                        try context.diagnostic_context.emitToken(path, cast.token, "`as!` from packed struct requires an explicit-width integer target", .{});
                        return SemaError.SemanticFailed;
                    }

                    const packed_bits = try packedStructBitWidth(context, program, try subject.canonicalTypeId(context));
                    const int_bits = namedIntBitWidth(context, target_name.?);
                    if (packed_bits != null and int_bits != null and packed_bits.? == int_bits.?) {
                        out.* = .{ .cast = .{
                            .subject = subject.expr,
                            .target_type_id = target,
                            .union_case_name = null,
                            .fallible = false,
                            .reinterpret = true,
                        } };
                        return makeTypedExprFromId(out, target);
                    }

                    try context.diagnostic_context.emitToken(path, cast.token, "`as!` width mismatch: packed struct `{s}` is {d} bits but target `{s}` is {d} bits", .{
                        subject_name.?,
                        packed_bits orelse 0,
                        target_name.?,
                        int_bits orelse 0,
                    });
                    return SemaError.SemanticFailed;
                }

                if (target_kind == .int and target_name != null and subject.kind(context) == .raw) {
                    out.* = .{ .cast = .{
                        .subject = subject.expr,
                        .target_type_id = target,
                        .union_case_name = null,
                        .fallible = false,
                        .reinterpret = true,
                    } };
                    return makeTypedExprFromId(out, target);
                }

                if (target_kind == .int and target_name != null and subject.kind(context) == .int) {
                    const source_name = subject_name orelse {
                        try context.diagnostic_context.emitToken(path, cast.token, "`as!` integer sources must have an explicit width; cast to `uN`/`iN` first", .{});
                        return SemaError.SemanticFailed;
                    };
                    const source_bits = namedIntBitWidth(context, source_name);
                    const target_bits = namedIntBitWidth(context, target_name.?);
                    if (source_bits != null and target_bits != null and source_bits.? == target_bits.?) {
                        out.* = .{ .cast = .{
                            .subject = subject.expr,
                            .target_type_id = target,
                            .union_case_name = null,
                            .fallible = false,
                            .reinterpret = true,
                        } };
                        return makeTypedExprFromId(out, target);
                    }

                    try context.diagnostic_context.emitToken(path, cast.token, "`as!` width mismatch: source `{s}` is {d} bits but target `{s}` is {d} bits", .{
                        source_name,
                        source_bits orelse 0,
                        target_name.?,
                        target_bits orelse 0,
                    });
                    return SemaError.SemanticFailed;
                }

                if (target_kind == .float and target_name != null and subject.kind(context) == .int) {
                    const source_name = subject_name orelse {
                        try context.diagnostic_context.emitToken(path, cast.token, "`as!` integer sources must have an explicit width; cast to `uN`/`iN` first", .{});
                        return SemaError.SemanticFailed;
                    };
                    const source_bits = namedIntBitWidth(context, source_name);
                    const target_bits = namedFloatBitWidth(target_name.?);
                    if (source_bits != null and target_bits != null and source_bits.? == target_bits.?) {
                        out.* = .{ .cast = .{
                            .subject = subject.expr,
                            .target_type_id = target,
                            .union_case_name = null,
                            .fallible = false,
                            .reinterpret = true,
                        } };
                        return makeTypedExprFromId(out, target);
                    }

                    try context.diagnostic_context.emitToken(path, cast.token, "`as!` width mismatch: source `{s}` is {d} bits but target `{s}` is {d} bits", .{
                        source_name,
                        source_bits orelse 0,
                        target_name.?,
                        target_bits orelse 0,
                    });
                    return SemaError.SemanticFailed;
                }

                if (target_kind == .int and target_name != null and subject.kind(context) == .float) {
                    const source_name = subject_name orelse {
                        try context.diagnostic_context.emitToken(path, cast.token, "`as!` floating-point sources must have an explicit width; cast to `f32`/`f64` first", .{});
                        return SemaError.SemanticFailed;
                    };
                    const source_bits = namedFloatBitWidth(source_name);
                    const target_bits = namedIntBitWidth(context, target_name.?);
                    if (source_bits != null and target_bits != null and source_bits.? == target_bits.?) {
                        out.* = .{ .cast = .{
                            .subject = subject.expr,
                            .target_type_id = target,
                            .union_case_name = null,
                            .fallible = false,
                            .reinterpret = true,
                        } };
                        return makeTypedExprFromId(out, target);
                    }

                    try context.diagnostic_context.emitToken(path, cast.token, "`as!` width mismatch: source `{s}` is {d} bits but target `{s}` is {d} bits", .{
                        source_name,
                        source_bits orelse 0,
                        target_name.?,
                        target_bits orelse 0,
                    });
                    return SemaError.SemanticFailed;
                }

                if (target_kind == .@"struct" and target_name != null) {
                    if (!try isPackedStructType(context, program, target)) {
                        try context.diagnostic_context.emitToken(path, cast.token, "`as!` only supports packed struct/int bit reinterpretation; `{s}` is not packed", .{target_name.?});
                        return SemaError.SemanticFailed;
                    }
                    if (subject.kind(context) != .int) {
                        try context.diagnostic_context.emitToken(path, cast.token, "`as!` to packed struct requires an explicit-width integer source", .{});
                        return SemaError.SemanticFailed;
                    }
                    const source_name = subject_name orelse {
                        try context.diagnostic_context.emitToken(path, cast.token, "`as!` integer sources must have an explicit width; cast to `uN`/`iN` first", .{});
                        return SemaError.SemanticFailed;
                    };

                    const packed_bits = try packedStructBitWidth(context, program, target);
                    const int_bits = namedIntBitWidth(context, source_name);
                    if (packed_bits != null and int_bits != null and packed_bits.? == int_bits.?) {
                        out.* = .{ .cast = .{
                            .subject = subject.expr,
                            .target_type_id = target,
                            .union_case_name = null,
                            .fallible = false,
                            .reinterpret = true,
                        } };
                        return makeTypedExprFromId(out, target);
                    }

                    try context.diagnostic_context.emitToken(path, cast.token, "`as!` width mismatch: source `{s}` is {d} bits but packed struct `{s}` is {d} bits", .{
                        source_name,
                        int_bits orelse 0,
                        target_name.?,
                        packed_bits orelse 0,
                    });
                    return SemaError.SemanticFailed;
                }

                if (target_kind == .raw) {
                    if (subject.kind(context) != .int and subject.kind(context) != .raw) {
                        try context.diagnostic_context.emitToken(path, cast.token, "`as!` to raw pointer requires an integer or raw pointer source", .{});
                        return SemaError.SemanticFailed;
                    }
                    out.* = .{ .cast = .{
                        .subject = subject.expr,
                        .target_type_id = target,
                        .union_case_name = null,
                        .fallible = false,
                        .reinterpret = true,
                    } };
                    return makeTypedExprFromId(out, target);
                }

                try context.diagnostic_context.emitToken(path, cast.token, "`as!` requires packed/integer bit reinterpretation or raw-address integer/pointer rebinding", .{});
                return SemaError.SemanticFailed;
            }

            if (subject.kind(context) == .int and target_kind == .rune) {
                out.* = .{ .cast = .{
                    .subject = subject.expr,
                    .target_type_id = target,
                    .union_case_name = null,
                    .fallible = cast.fallible,
                    .reinterpret = false,
                } };
                const result_ty = if (cast.fallible) try canonicalOptionalTypeId(context, target) else target;
                return try makeTypedExprWithProvenance(
                    context,
                    out,
                    result_ty,
                    try propagatedProvenanceForTypeId(context, path, program, current_module, result_ty, subject.provenance),
                );
            }

            if (subject.kind(context) == .int and target_kind == .int) {
                out.* = .{ .cast = .{
                    .subject = subject.expr,
                    .target_type_id = target,
                    .union_case_name = null,
                    .fallible = cast.fallible,
                    .reinterpret = false,
                } };
                const result_ty = if (cast.fallible) try canonicalOptionalTypeId(context, target) else target;
                return try makeTypedExprWithProvenance(
                    context,
                    out,
                    result_ty,
                    try propagatedProvenanceForTypeId(context, path, program, current_module, result_ty, subject.provenance),
                );
            }

            if (subject.kind(context) == .int and target_kind == .float) {
                out.* = .{ .cast = .{
                    .subject = subject.expr,
                    .target_type_id = target,
                    .union_case_name = null,
                    .fallible = cast.fallible,
                    .reinterpret = false,
                } };
                const result_ty = if (cast.fallible) try canonicalOptionalTypeId(context, target) else target;
                return try makeTypedExprWithProvenance(
                    context,
                    out,
                    result_ty,
                    try propagatedProvenanceForTypeId(context, path, program, current_module, result_ty, subject.provenance),
                );
            }

            if (subject.kind(context) == .float and target_kind == .int) {
                out.* = .{ .cast = .{
                    .subject = subject.expr,
                    .target_type_id = target,
                    .union_case_name = null,
                    .fallible = cast.fallible,
                    .reinterpret = false,
                } };
                const result_ty = if (cast.fallible) try canonicalOptionalTypeId(context, target) else target;
                return try makeTypedExprWithProvenance(
                    context,
                    out,
                    result_ty,
                    try propagatedProvenanceForTypeId(context, path, program, current_module, result_ty, subject.provenance),
                );
            }

            if (subject.kind(context) == .float and target_kind == .float) {
                out.* = .{ .cast = .{
                    .subject = subject.expr,
                    .target_type_id = target,
                    .union_case_name = null,
                    .fallible = cast.fallible,
                    .reinterpret = false,
                } };
                const result_ty = if (cast.fallible) try canonicalOptionalTypeId(context, target) else target;
                return try makeTypedExprWithProvenance(
                    context,
                    out,
                    result_ty,
                    try propagatedProvenanceForTypeId(context, path, program, current_module, result_ty, subject.provenance),
                );
            }

            if (subject.kind(context) == .int and target_kind == .@"enum") {
                out.* = .{ .cast = .{
                    .subject = subject.expr,
                    .target_type_id = target,
                    .union_case_name = null,
                    .fallible = cast.fallible,
                    .reinterpret = false,
                } };
                const result_ty = if (cast.fallible) try canonicalOptionalTypeId(context, target) else target;
                return try makeTypedExprWithProvenance(
                    context,
                    out,
                    result_ty,
                    try propagatedProvenanceForTypeId(context, path, program, current_module, result_ty, subject.provenance),
                );
            }

            if (subject.kind(context) == .@"enum" and target_kind == .int) {
                out.* = .{ .cast = .{
                    .subject = subject.expr,
                    .target_type_id = target,
                    .union_case_name = null,
                    .fallible = cast.fallible,
                    .reinterpret = false,
                } };
                const result_ty = if (cast.fallible) try canonicalOptionalTypeId(context, target) else target;
                return try makeTypedExprWithProvenance(
                    context,
                    out,
                    result_ty,
                    try propagatedProvenanceForTypeId(context, path, program, current_module, result_ty, subject.provenance),
                );
            }

            if (subject.kind(context) == .optional and canonicalTypeNode(context, subject.type_id).optional == target) {
                if (try typeIsOwnedValue(context, path, program, target)) {
                    try lowerImplicitHandoff(context, path, program, locals, cast.subject, subject.type_id, subject.expr);
                    try markCheckedNamedHandoff(context, path, program, @constCast(locals), cast.subject, subject.expr, subject.type_id);
                }
                out.* = .{ .cast = .{
                    .subject = subject.expr,
                    .target_type_id = target,
                    .union_case_name = null,
                    .fallible = cast.fallible,
                    .reinterpret = false,
                } };
                const result_ty = if (cast.fallible) try canonicalOptionalTypeId(context, target) else target;
                return try makeTypedExprWithProvenance(
                    context,
                    out,
                    result_ty,
                    try propagatedProvenanceForTypeId(context, path, program, current_module, result_ty, subject.provenance),
                );
            }

            if (subject.kind(context) == .@"union") {
                const union_name = subject_name.?;
                const decl_id = canonicalNominalDeclId(context, subject.type_id) orelse return error.SemanticFailed;
                const decl = lookupUnionDeclById(context, program, decl_id) orelse return error.SemanticFailed;
                if (decl.kind == .type_union) {
                    var matched_case: ?[]const u8 = null;
                    for (decl.variants) |variant| {
                        const variant_type = try parseCanonicalType(context, path, program, decl.module_name, variant);
                        if (variant_type != target) continue;
                        const case_name = try formatCanonicalTypeDisplay(context, variant_type);
                        try context.output.generated_strings.append(allocator, case_name);
                        matched_case = case_name;
                        break;
                    }
                    if (matched_case) |case_name| {
                        if (try typeIsOwnedValue(context, path, program, target)) {
                            try lowerImplicitHandoff(context, path, program, locals, cast.subject, subject.type_id, subject.expr);
                            try markCheckedNamedHandoff(context, path, program, @constCast(locals), cast.subject, subject.expr, subject.type_id);
                        }
                        out.* = .{ .cast = .{
                            .subject = subject.expr,
                            .source_union_decl_id = decl_id,
                            .target_type_id = target,
                            .union_case_name = case_name,
                            .fallible = cast.fallible,
                            .reinterpret = false,
                        } };
                        const result_ty = if (cast.fallible) try canonicalOptionalTypeId(context, target) else target;
                        return try makeTypedExprWithProvenance(
                            context,
                            out,
                            result_ty,
                            try propagatedProvenanceForTypeId(context, path, program, current_module, result_ty, subject.provenance),
                        );
                    }
                }
                var matched_case: ?ast.UnionField = null;
                for (decl.fields) |field| {
                    const type_name = field.type_name orelse continue;
                    const field_type = try parseCanonicalType(context, path, program, decl.module_name, type_name);
                    if (field_type != target) continue;
                    if (matched_case != null) {
                        const display = try formatCanonicalTypeDisplay(context, target);
                        defer allocator.free(display);
                        try context.diagnostic_context.emitToken(path, cast.token, "union `{s}` has multiple `{s}` payload cases; use field projection or `if is` narrowing", .{ union_name, display });
                        return SemaError.SemanticFailed;
                    }
                    matched_case = field;
                }
                if (matched_case) |field| {
                    if (try typeIsOwnedValue(context, path, program, target)) {
                        try lowerImplicitHandoff(context, path, program, locals, cast.subject, subject.type_id, subject.expr);
                        try markCheckedNamedHandoff(context, path, program, @constCast(locals), cast.subject, subject.expr, subject.type_id);
                    }
                    out.* = .{ .cast = .{
                        .subject = subject.expr,
                        .source_union_decl_id = decl_id,
                        .target_type_id = target,
                        .union_case_name = field.name,
                        .fallible = cast.fallible,
                        .reinterpret = false,
                    } };
                    const result_ty = if (cast.fallible) try canonicalOptionalTypeId(context, target) else target;
                    return try makeTypedExprWithProvenance(
                        context,
                        out,
                        result_ty,
                        try propagatedProvenanceForTypeId(context, path, program, current_module, result_ty, subject.provenance),
                    );
                }
            }

            try context.diagnostic_context.emitToken(path, cast.token, "checked `as` casts require integer, float, or enum operands", .{});
            return SemaError.SemanticFailed;
        }

        pub fn lowerNarrowIf(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            return_type: semantic_types.TypeId,
            locals: *std.ArrayListUnmanaged(LocalBinding),
            if_stmt: ast.If,
            allow_same_name_capture: bool,
        ) SemaError!sir.Stmt {
            const is_test = if_stmt.condition.is_test;
            const subject = try lowerExpr(context, allocator, path, program, current_module, globals, locals.items, is_test.subject, null);
            errdefer subject.expr.destroy(allocator);

            var if_kind: sir.IfKind = .plain;
            var union_decl_id: ?identity.DeclId = null;
            var case_name: ?[]const u8 = null;
            var capture_type: ?semantic_types.TypeId = null;

            switch (is_test.kind) {
                .optional_none => {
                    const subject_type_id = if (subject.kind(context) == .ref) canonicalRefTarget(context, subject.type_id) else subject.type_id;
                    if (canonicalTypeNode(context, subject_type_id).* != .optional) {
                        try context.diagnostic_context.emitToken(path, is_test.token, "`is none` requires an optional value", .{});
                        return SemaError.SemanticFailed;
                    }
                    if_kind = .optional_none;
                },
                .optional_some => {
                    const subject_type_id = if (subject.kind(context) == .ref) canonicalRefTarget(context, subject.type_id) else subject.type_id;
                    const optional_payload_id = switch (canonicalTypeNode(context, subject_type_id).*) {
                        .optional => |payload| payload,
                        else => {
                            try context.diagnostic_context.emitToken(path, is_test.token, "`is name` requires an optional value", .{});
                            return SemaError.SemanticFailed;
                        },
                    };
                    if_kind = .optional_some;
                    capture_type = optional_payload_id;
                },
                .union_case => {
                    const resolved = try resolveTagNarrowCase(context, path, program, current_module, subject, is_test);
                    if_kind = .union_case;
                    union_decl_id = resolved.union_decl_id;
                    case_name = resolved.case_name;
                    capture_type = resolved.capture_type;
                },
            }

            if (is_test.capture_name) |capture_name| {
                if (!allow_same_name_capture and findLocal(locals.items, capture_name) != null) {
                    try context.diagnostic_context.emitToken(path, is_test.token, "duplicate local `{s}`", .{capture_name});
                    return SemaError.SemanticFailed;
                }
                var binding = try localBinding(context, capture_name, capture_type.?, false, false);
                if (is_test.kind == .optional_some) binding.generic_shape = try loweredProjectionShape(context, subject.generic_shape, capture_type, .payload);
                binding.generic_origin = try payloadOrigin(context, capture_type, subject);
                binding.provenance = try switchPayloadCaptureProvenance(context, path, program, current_module, globals, locals.items, is_test.subject, capture_type.?, subject.provenance.derived());
                binding.borrowed_place = try borrowedPlaceDependencyForStoredValue(context, path, program, current_module, globals, locals.items, is_test.subject, capture_type.?, binding.provenance);
                binding.projection_origin = is_test.subject;
                if (is_test.capture_token) |capture_token| {
                    try maybeRecordSemanticHoverFact(context, allocator, path, program, current_module, capture_token, capture_name, binding.type_id, binding.provenance);
                }
                const lowered_bodies = try lowerJoinedIfBodies(
                    context,
                    allocator,
                    path,
                    program,
                    current_module,
                    globals,
                    return_type,
                    locals,
                    if_stmt.then_body,
                    if_stmt.else_body,
                    binding,
                );
                return .{ .@"if" = .{
                    .kind = if_kind,
                    .condition = subject.expr,
                    .union_decl_id = union_decl_id,
                    .case_name = case_name,
                    .capture_name = capture_name,
                    .capture_binding_id = binding.binding_id,
                    .capture_type_id = capture_type.?,
                    .capture_path = checkedCapturePath(checkedCaptureOrigin(context, subject.expr), checkedIfPayloadCase(context, program, if_kind, subject.type_id, union_decl_id, case_name)),
                    .then_body = lowered_bodies.then_body,
                    .else_body = lowered_bodies.else_body,
                } };
            }

            const lowered_bodies = try lowerJoinedIfBodies(
                context,
                allocator,
                path,
                program,
                current_module,
                globals,
                return_type,
                locals,
                if_stmt.then_body,
                if_stmt.else_body,
                null,
            );
            return .{ .@"if" = .{
                .kind = if_kind,
                .condition = subject.expr,
                .union_decl_id = union_decl_id,
                .case_name = case_name,
                .capture_name = null,
                .capture_type_id = null,
                .then_body = lowered_bodies.then_body,
                .else_body = lowered_bodies.else_body,
            } };
        }

        pub fn lowerExpectedResultCasePayload(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            token: lexer.Token,
            result_type_id: semantic_types.TypeId,
            result_case: sir.ResultCase,
            value: ?*ast.Expr,
        ) SemaError!ResultCasePayload {
            const result_type = canonicalTypeNode(context, result_type_id).result;
            const case_name = result_case.sourceName();
            const payload_type_id = switch (result_case) {
                .ok => result_type.ok,
                .err => result_type.err,
            };

            return if (value) |value_expr| blk: {
                if (canonicalTypeIsVoidLike(context, payload_type_id)) {
                    try context.diagnostic_context.emitToken(path, firstExprToken(value_expr), "result case `{s}` does not take a payload", .{case_name});
                    return SemaError.SemanticFailed;
                }
                const lowered = try lowerExprInContext(context, allocator, path, program, current_module, globals, locals, value_expr, payload_type_id);
                errdefer lowered.expr.destroy(allocator);
                try expectType(context, path, firstExprToken(value_expr), payload_type_id, lowered.type_id);
                try lowerImplicitHandoff(context, path, program, locals, value_expr, payload_type_id, lowered.expr);
                try markCheckedNamedHandoff(context, path, program, @constCast(locals), value_expr, lowered.expr, payload_type_id);
                break :blk .{ .expr = lowered.expr, .provenance = lowered.provenance };
            } else blk: {
                if (!canonicalTypeIsVoidLike(context, payload_type_id)) {
                    try context.diagnostic_context.emitToken(path, token, "result case `{s}` requires a payload", .{case_name});
                    return SemaError.SemanticFailed;
                }
                break :blk .{ .expr = null, .provenance = .none() };
            };
        }

        pub fn lowerTryExpr(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            try_expr: ast.TryExpr,
            expected_type_id: ?semantic_types.TypeId,
        ) SemaError!TypedExpr {
            const operand_expected: ?semantic_types.TypeId = if (expected_type_id) |expected| blk: {
                const return_type = context.function_state.current_return_type orelse break :blk null;
                const return_node = canonicalTypeNode(context, return_type);
                if (return_node.* != .result) break :blk null;
                const expected_node = canonicalTypeNode(context, expected);
                const payload = if (expected_node.* == .result) expected_node.result.ok else expected;
                break :blk try canonicalResultTypeId(context, payload, return_node.result.err);
            } else null;
            var value = try lowerExpr(context, allocator, path, program, current_module, globals, locals, try_expr.expr, operand_expected);
            errdefer value.expr.destroy(allocator);
            if (value.kind(context) != .result) {
                if (value.kind(context) == .optional) {
                    try context.diagnostic_context.emitToken(path, try_expr.token, "`try` propagates only result errors, not optional absence; test the optional and `return none` explicitly", .{});
                    return SemaError.SemanticFailed;
                }
                // The payload of a binder-typed result is not a concrete result yet; the
                // specialization re-checks `try` against the substituted type.
                if (type_resolution.containsDefinitionSiteBinder(canonicalTypeInterner(context), value.type_id)) {
                    const payload = try loweredProjectionShape(context, value.generic_shape, null, .payload);
                    return try deferredDefinitionSiteValue(context, allocator, path, program, current_module, &value, out, try definitionSiteDeferredType(context, "try"), payload);
                }
                try context.diagnostic_context.emitToken(path, try_expr.token, "`try` requires a result value", .{});
                return SemaError.SemanticFailed;
            }

            const result = canonicalTypeNode(context, value.type_id).result;
            const return_type = context.function_state.current_return_type orelse {
                try context.diagnostic_context.emitToken(path, try_expr.token, "`try` expression requires a result return type; optional absence must be tested and returned as `none` explicitly", .{});
                return SemaError.SemanticFailed;
            };
            const return_result = switch (canonicalTypeNode(context, return_type).*) {
                .result => |function_result| function_result,
                else => {
                    try context.diagnostic_context.emitToken(path, try_expr.token, "`try` expression requires a result return type; optional absence must be tested and returned as `none` explicitly", .{});
                    return SemaError.SemanticFailed;
                },
            };
            if (canonicalTypeIsVoidLike(context, result.ok)) {
                try context.diagnostic_context.emitToken(path, try_expr.token, "`try` expression requires a non-void success value", .{});
                return SemaError.SemanticFailed;
            }
            const widen_ordinal = try tryErrorWidenOrdinal(context, path, program, return_result.err, result.err, try_expr.token);
            if (return_result.err != result.err and widen_ordinal == null and
                !try tryErrorUnionWidenAllowed(context, path, program, return_result.err, result.err))
            {
                const expected_error = try formatCanonicalTypeDisplay(context, return_result.err);
                defer context.allocator.free(expected_error);
                const actual_error = try formatCanonicalTypeDisplay(context, result.err);
                defer context.allocator.free(actual_error);
                const notes = [_][]const u8{"the propagated error type must match the function result error type or be one of its enum union members"};
                try context.diagnostic_context.emitTokenWith(path, try_expr.token, .{
                    .code = .type_mismatch,
                    .notes = &notes,
                    .help = "add the enum to the function result error union or convert the error",
                }, "`try` error type mismatch: expected {s}, got {s}", .{ expected_error, actual_error });
                return SemaError.SemanticFailed;
            }

            // `try` consumes its result carrier before selecting the success payload.
            // Record a named carrier's checked move at this boundary, where the
            // lowered expression and its binding identity are both available.
            try lowerImplicitHandoff(context, path, program, locals, try_expr.expr, value.type_id, value.expr);
            try markCheckedNamedHandoff(context, path, program, @constCast(locals), try_expr.expr, value.expr, value.type_id);

            out.* = .{ .@"try" = .{
                .expr = value.expr,
                .site_line = @intCast(try_expr.token.line),
                .result_ok_type_id = result.ok,
                .result_err_type_id = result.err,
                .widen_ordinal = widen_ordinal,
            } };
            return makeTypedExprFromIdWithProvenance(out, result.ok, value.provenance.derived());
        }

        pub fn lowerUnary(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            unary: ast.Unary,
        ) SemaError!TypedExpr {
            if (unary.op == .take) {
                var take_expr: ast.Expr = .{ .unary = unary };
                if (try lowerTakeIndexLocal(context, allocator, path, program, current_module, globals, locals, out, &take_expr, null)) |taken| {
                    try recordLoweredOperationUse(context, "take", firstExprToken(unary.expr), taken);
                    return taken;
                }
                try context.diagnostic_context.emitToken(path, firstExprToken(unary.expr), "`take` requires a `[:]?T` local index", .{});
                return SemaError.SemanticFailed;
            }

            const expected_type_id = switch (unary.op) {
                .not => try canonicalPrimitiveTypeId(context, .bool),
                .bit_not => null,
                .negate => null,
                .take => unreachable,
            };
            const expr = try lowerExpr(context, allocator, path, program, current_module, globals, locals, unary.expr, expected_type_id);
            var owns_expr = true;
            errdefer if (owns_expr) expr.expr.destroy(allocator);
            try recordLoweredOperationUse(context, @tagName(unary.op), firstExprToken(unary.expr), expr);
            switch (unary.op) {
                .not => try expectType(context, path, firstExprToken(unary.expr), try canonicalPrimitiveTypeId(context, .bool), expr.type_id),
                .bit_not => {
                    if (expr.kind(context) != .int and !isFlagsType(context, program, expr.type_id)) {
                        try context.diagnostic_context.emitToken(path, firstExprToken(unary.expr), "bitwise complement requires an int or flags value", .{});
                        return SemaError.SemanticFailed;
                    }
                },
                .negate => {
                    if (expr.kind(context) != .int and expr.kind(context) != .float) {
                        try context.diagnostic_context.emitToken(path, firstExprToken(unary.expr), "unary negation requires an integer or float operand", .{});
                        return SemaError.SemanticFailed;
                    }
                    if (expr.kind(context) == .int and isUnsignedIntegerType(context, expr.type_id)) {
                        try context.diagnostic_context.emitToken(path, firstExprToken(unary.expr), "unary negation requires a signed integer or float operand", .{});
                        return SemaError.SemanticFailed;
                    }
                },
                .take => unreachable,
            }

            owns_expr = false;
            out.* = .{ .unary = .{
                .op = switch (unary.op) {
                    .not => .not,
                    .bit_not => .bit_not,
                    .negate => .negate,
                    .take => unreachable,
                },
                .expr = expr.expr,
            } };
            const result_type_id = switch (unary.op) {
                .not => try canonicalPrimitiveTypeId(context, .bool),
                .bit_not => expr.type_id,
                .negate => expr.type_id,
                .take => unreachable,
            };
            return makeTypedExprFromIdWithProvenance(
                out,
                result_type_id,
                switch (unary.op) {
                    .not => .none(),
                    .bit_not => try propagatedProvenanceForTypeId(context, path, program, current_module, result_type_id, expr.provenance),
                    .negate => try propagatedProvenanceForTypeId(context, path, program, current_module, result_type_id, expr.provenance),
                    .take => unreachable,
                },
            );
        }

        pub fn lowerBinary(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            binary: ast.Binary,
        ) SemaError!TypedExpr {
            if ((binary.op == .eq or binary.op == .ne) and binary.left.* == .none) {
                const right = try lowerExpr(context, allocator, path, program, current_module, globals, locals, binary.right, null);
                errdefer right.expr.destroy(allocator);
                const left = try lowerExpr(context, allocator, path, program, current_module, globals, locals, binary.left, right.type_id);
                errdefer left.expr.destroy(allocator);
                try expectType(context, path, firstExprToken(binary.left), right.type_id, left.type_id);
                try recordLoweredOperationUse(context, @tagName(binary.op), firstExprToken(binary.left), left);
                try recordLoweredOperationUse(context, @tagName(binary.op), firstExprToken(binary.right), right);
                out.* = .{ .binary = .{
                    .op = if (binary.op == .eq) .eq else .ne,
                    .left = left.expr,
                    .right = right.expr,
                } };
                return makeTypedExprFromId(out, try canonicalPrimitiveTypeId(context, .bool));
            }
            if ((binary.op == .eq or binary.op == .ne) and binary.right.* == .none) {
                const left = try lowerExpr(context, allocator, path, program, current_module, globals, locals, binary.left, null);
                errdefer left.expr.destroy(allocator);
                const right = try lowerExpr(context, allocator, path, program, current_module, globals, locals, binary.right, left.type_id);
                errdefer right.expr.destroy(allocator);
                try expectType(context, path, firstExprToken(binary.right), left.type_id, right.type_id);
                try recordLoweredOperationUse(context, @tagName(binary.op), firstExprToken(binary.left), left);
                try recordLoweredOperationUse(context, @tagName(binary.op), firstExprToken(binary.right), right);
                out.* = .{ .binary = .{
                    .op = if (binary.op == .eq) .eq else .ne,
                    .left = left.expr,
                    .right = right.expr,
                } };
                return makeTypedExprFromId(out, try canonicalPrimitiveTypeId(context, .bool));
            }

            const left = try lowerExpr(context, allocator, path, program, current_module, globals, locals, binary.left, null);
            errdefer left.expr.destroy(allocator);
            const right_literal_expected_type_id: ?semantic_types.TypeId = switch (binary.right.*) {
                .int => if (left.kind(context) == .int) left.type_id else null,
                .float => if (left.kind(context) == .float) left.type_id else null,
                .rune => if (left.kind(context) == .int) left.type_id else null,
                else => null,
            };
            const right_expected_type_id: ?semantic_types.TypeId = switch (binary.op) {
                .wrap_add, .wrap_sub, .wrap_mul, .mod, .bit_and, .bit_or, .bit_xor => left.type_id,
                .eq, .ne => if (left.kind(context) == .@"enum") left.type_id else right_literal_expected_type_id,
                .add => if (canonicalTypeNode(context, left.type_id).* == .raw) try canonicalIntegerTypeId(context, "usize") else right_literal_expected_type_id,
                else => right_literal_expected_type_id,
            };
            const right = if (right_expected_type_id != null)
                try lowerExprInContext(context, allocator, path, program, current_module, globals, locals, binary.right, right_expected_type_id)
            else
                try lowerExpr(context, allocator, path, program, current_module, globals, locals, binary.right, null);
            errdefer right.expr.destroy(allocator);
            try recordLoweredOperationUse(context, @tagName(binary.op), firstExprToken(binary.left), left);
            try recordLoweredOperationUse(context, @tagName(binary.op), firstExprToken(binary.right), right);

            if (binary.op == .add and (left.kind(context) == .string or right.kind(context) == .string)) {
                try context.diagnostic_context.emitToken(path, firstExprToken(binary.left), "string concatenation with `+` is not supported; use `$\"...{{...}}\"` interpolation", .{});
                return SemaError.SemanticFailed;
            }

            const bool_type_id = try canonicalPrimitiveTypeId(context, .bool);
            const result_type_id: semantic_types.TypeId = switch (binary.op) {
                .add, .sub, .mul, .div => blk: {
                    if (binary.op == .add and canonicalTypeNode(context, left.type_id).* == .raw) {
                        if (context.function_state.unchecked_depth == 0) {
                            try context.diagnostic_context.emitToken(path, firstExprToken(binary.left), "raw pointer arithmetic requires `unchecked`", .{});
                            return SemaError.SemanticFailed;
                        }
                        const raw = canonicalTypeNode(context, left.type_id).raw;
                        if (canonicalTypeNode(context, raw.target).* == .primitive and
                            (canonicalTypeNode(context, raw.target).primitive == .void or canonicalTypeNode(context, raw.target).primitive == .c_void))
                        {
                            try context.diagnostic_context.emitToken(path, firstExprToken(binary.left), "raw pointer arithmetic requires a sized pointee", .{});
                            return SemaError.SemanticFailed;
                        }
                        try expectType(context, path, firstExprToken(binary.right), try canonicalIntegerTypeId(context, "usize"), right.type_id);
                        break :blk left.type_id;
                    }
                    // An unconstrained binder may still be substituted with a numeric
                    // type, so the operator check is deferred to the specialization.
                    if (isDefinitionSiteBinder(context, left.type_id) or isDefinitionSiteBinder(context, right.type_id)) break :blk left.type_id;
                    break :blk try resolveNumericBinaryType(context, path, firstExprToken(binary.left), firstExprToken(binary.right), left.type_id, right.type_id);
                },
                .wrap_add, .wrap_sub, .wrap_mul => blk: {
                    try expectType(context, path, firstExprToken(binary.right), left.type_id, right.type_id);
                    if (left.kind(context) != .int) {
                        try context.diagnostic_context.emitToken(path, firstExprToken(binary.left), "wrapping arithmetic requires integer operands", .{});
                        return SemaError.SemanticFailed;
                    }
                    break :blk left.type_id;
                },
                .mod => blk: {
                    try expectType(context, path, firstExprToken(binary.right), left.type_id, right.type_id);
                    if (left.kind(context) != .int) {
                        try context.diagnostic_context.emitToken(path, firstExprToken(binary.left), "`%` requires integer operands", .{});
                        return SemaError.SemanticFailed;
                    }
                    break :blk left.type_id;
                },
                .shl, .shr => blk: {
                    // An unconstrained binder may still be substituted with an integer,
                    // so the kind check is deferred to the specialization.
                    if ((left.kind(context) != .int and !isDefinitionSiteBinder(context, left.type_id)) or
                        (right.kind(context) != .int and !isDefinitionSiteBinder(context, right.type_id)))
                    {
                        try context.diagnostic_context.emitToken(path, firstExprToken(binary.left), "shift operators require integer operands", .{});
                        return SemaError.SemanticFailed;
                    }
                    break :blk left.type_id;
                },
                .bit_and, .bit_or, .bit_xor => blk: {
                    try expectType(context, path, firstExprToken(binary.right), left.type_id, right.type_id);
                    if (left.kind(context) == .int) break :blk left.type_id;
                    if (isFlagsType(context, program, left.type_id)) break :blk left.type_id;
                    if (isDefinitionSiteBinder(context, left.type_id)) break :blk left.type_id;
                    try context.diagnostic_context.emitToken(path, firstExprToken(binary.left), "bitwise operators require ints or flags values", .{});
                    return SemaError.SemanticFailed;
                },
                .in => blk: {
                    if (right.kind(context) == .@"enum" and isFlagsType(context, program, try right.canonicalTypeId(context))) {
                        try expectType(context, path, firstExprToken(binary.left), right.type_id, left.type_id);
                        break :blk bool_type_id;
                    }
                    try context.diagnostic_context.emitToken(path, firstExprToken(binary.right), "`in` is defined only for flags values; use an ordinary `contains` method for collections", .{});
                    return SemaError.SemanticFailed;
                },
                .eq, .ne => blk: {
                    if ((left.kind(context) == .int or left.kind(context) == .float) and (right.kind(context) == .int or right.kind(context) == .float)) {
                        _ = try resolveNumericBinaryType(context, path, firstExprToken(binary.left), firstExprToken(binary.right), left.type_id, right.type_id);
                    } else if (type_resolution.canonicalSequenceEqualityItemType(canonical.displayContext(context), left.type_id, right.type_id)) |item_type_id| {
                        try type_resolution.expectSequenceEqualityElement(canonical.displayContext(context), &context.diagnostic_context, path, firstExprToken(binary.left), item_type_id);
                    } else {
                        try expectType(context, path, firstExprToken(binary.right), left.type_id, right.type_id);
                        try type_resolution.expectEqualitySupported(canonical.displayContext(context), &context.diagnostic_context, path, firstExprToken(binary.left), left.type_id);
                    }
                    break :blk bool_type_id;
                },
                .lt, .le, .gt, .ge => blk: {
                    _ = try resolveNumericBinaryType(context, path, firstExprToken(binary.left), firstExprToken(binary.right), left.type_id, right.type_id);
                    break :blk bool_type_id;
                },
                .@"and", .@"or" => blk: {
                    try expectType(context, path, firstExprToken(binary.left), try canonicalPrimitiveTypeId(context, .bool), left.type_id);
                    try expectType(context, path, firstExprToken(binary.right), try canonicalPrimitiveTypeId(context, .bool), right.type_id);
                    break :blk bool_type_id;
                },
            };

            out.* = .{ .binary = .{
                .op = switch (binary.op) {
                    .add => .add,
                    .wrap_add => .wrap_add,
                    .sub => .sub,
                    .wrap_sub => .wrap_sub,
                    .mul => .mul,
                    .wrap_mul => .wrap_mul,
                    .div => .div,
                    .mod => .mod,
                    .shl => .shl,
                    .shr => .shr,
                    .bit_and => .bit_and,
                    .bit_or => .bit_or,
                    .bit_xor => .bit_xor,
                    .in => .in,
                    .eq => .eq,
                    .ne => .ne,
                    .lt => .lt,
                    .le => .le,
                    .gt => .gt,
                    .ge => .ge,
                    .@"and" => .@"and",
                    .@"or" => .@"or",
                },
                .left = left.expr,
                .right = right.expr,
            } };
            return makeTypedExprFromId(out, result_type_id);
        }

        pub fn lowerCall(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            call: ast.Call,
            expected_type_id: ?semantic_types.TypeId,
        ) SemaError!TypedExpr {
            if (intrinsics.resolveCall(call.owner, call.callee)) |intrinsic| {
                switch (intrinsic) {
                    .builtin_print, .builtin_println => return lowerBuiltinPrintCall(context, allocator, path, program, current_module, globals, locals, out, call),
                    .builtin_assert => return lowerBuiltinAssertCall(context, allocator, path, program, current_module, globals, locals, out, call),
                    .string_from => return lowerBuiltinStringFromCall(context, allocator, path, program, current_module, globals, locals, out, call),
                    else => {},
                }
            }
            if (call.owner) |owner| {
                if (findProtocol(context, program, current_module, owner)) |protocol_decl| {
                    if (call.type_args.len != 0) {
                        try context.diagnostic_context.emitToken(path, call.callee_token, "qualified protocol calls do not accept explicit type arguments", .{});
                        return SemaError.SemanticFailed;
                    }
                    if (call.args.len == 0) {
                        try context.diagnostic_context.emitToken(path, call.callee_token, "qualified protocol call `{s}.{s}` requires a receiver argument", .{ owner, call.callee });
                        return SemaError.SemanticFailed;
                    }
                    const protocol_id = try registeredDeclId(context, protocol_decl.module_name, null, protocol_decl.name, .protocol);
                    return lowerMethodCallInternal(context, allocator, path, program, current_module, globals, locals, out, .{
                        .object = call.args[0].value,
                        .method = call.callee,
                        .method_token = call.callee_token,
                        .type_args = &.{},
                        .args = call.args[1..],
                    }, protocol_id);
                }
            }
            const resolved_callee = (try resolveAstFunction(context, program, current_module, call.owner, call.callee)) orelse {
                if (call.owner == null) {
                    if (findLocal(locals, call.callee)) |local| {
                        if (local.kind(context) == .function or local.kind(context) == .arrow_callable) {
                            return lowerIndirectCall(context, allocator, path, program, current_module, globals, locals, out, call, local);
                        }
                        // A binder may still be substituted with a callable type, so the
                        // definition-site trial lowers and discards the arguments and
                        // carries the callee through as a projection of its binder.
                        if (isDefinitionSiteBinder(context, local.type_id)) {
                            for (call.args) |arg| {
                                const arg_value = try lowerExpr(context, allocator, path, program, current_module, globals, locals, arg.value, null);
                                arg_value.expr.destroy(allocator);
                            }
                            out.* = .{ .local = call.callee };
                            var deferred = makeTypedExprFromId(out, local.type_id);
                            deferred.generic_shape = try context.generic.shapes.project(allocator, local.generic_shape);
                            deferred.generic_origin = projectedOrigin(local.generic_origin orelse receiverOriginFromType(context, local.type_id));
                            try finalizeAndRecordExprSemantics(context, path, program, current_module, &deferred);
                            return deferred;
                        }
                    }
                }
                if (call.owner) |owner| {
                    try context.diagnostic_context.emitToken(path, call.callee_token, "struct `{s}` has no namespace function `{s}`", .{ owner, call.callee });
                } else {
                    try emitUnknownCallable(context, path, program, current_module, call.callee_token, call.callee);
                }
                return SemaError.SemanticFailed;
            };
            const callee = resolved_callee.decl;
            try rejectIsolatedCallToFunction(context, allocator, path, program, current_module, globals, call.callee_token, callee);
            if (callee.params.len != call.args.len) {
                try context.diagnostic_context.emitToken(path, call.callee_token, "function `{s}` expects {d} args, got {d}", .{ call.callee, callee.params.len, call.args.len });
                return SemaError.SemanticFailed;
            }
            if (callee.type_params.len == 0 and call.type_args.len != 0) {
                try context.diagnostic_context.emitToken(path, call.callee_token, "function `{s}` does not accept explicit type arguments", .{call.callee});
                return SemaError.SemanticFailed;
            }
            if (callee.type_params.len == 0) {
                try validateBoundaryCall(context, allocator, path, program, current_module, globals, call, callee, null, null);
            }
            if (callee.intrinsic_name != null) {
                return lowerExplicitIntrinsicCall(context, allocator, path, program, current_module, globals, locals, out, call, callee);
            }

            var args: std.ArrayListUnmanaged(sir.CallArg) = .empty;
            errdefer {
                for (args.items) |arg| arg.deinit(allocator);
                args.deinit(allocator);
            }

            if (callee.type_params.len == 0) {
                try rejectBorrowedCallStateEscapes(context, path, program, current_module, globals, locals, call.args, callee, null, null);
                for (call.args, callee.params) |arg, param| {
                    const expected = try parseCanonicalType(context, path, program, callee.module_name, param.type_name);
                    try appendOwnedLowered(allocator, &args, try lowerCallArg(context, allocator, path, program, current_module, globals, locals, arg, expected, .{
                        .path = moduleSourcePath(program, callee.module_name, path),
                        .token = param.type_name.token,
                        .message = "parameter type declared here",
                    }));
                }
                if (std.mem.eql(u8, callee.module_name, "std.thread") and
                    callee.owner != null and std.mem.eql(u8, callee.owner.?, "TaskGroup") and
                    (std.mem.eql(u8, call.callee, "finish") or std.mem.eql(u8, call.callee, "cancel_and_wait")) and
                    call.args.len != 0)
                {
                    const receiver = call.args[0].value;
                    if (receiver.* == .field or receiver.* == .index) {
                        try context.diagnostic_context.emitToken(path, firstExprToken(receiver), "cannot consume concurrency handle through a projected place; keep the handle in a local and pass data or IDs through the aggregate", .{});
                        return error.SemanticFailed;
                    }
                }
                const return_type = try resolvedFunctionReturnType(context, path, program, callee, context.function_state.current_generic_params, context.function_state.current_generic_args);
                const owned_args = try args.toOwnedSlice(allocator);
                out.* = .{ .call = .{
                    .intrinsic_id = intrinsics.resolveDeclaration(callee.module_name, callee.owner, callee.name),
                    .decl_id = resolved_callee.id,
                    .module_name = callee.module_name,
                    .owner = call.owner,
                    .callee = call.callee,
                    .args = owned_args,
                } };
                try attachCheckedCallUse(context, out, return_type, context.function_state.active_source_decl_id, call.callee_token.offset);
                return try makeTypedExprWithProvenance(
                    context,
                    out,
                    return_type,
                    try inferredCallReturnProvenance(context, path, program, current_module, globals, locals, return_type, call.args, callee, null, null),
                );
            }

            if (intrinsics.resolveCall(call.owner, call.callee)) |intrinsic| {
                if (concurrency.contractForIntrinsic(intrinsic)) |contract| {
                    const resolved_args = if (call.type_args.len != 0)
                        try resolveExplicitGenericArgs(context, path, program, current_module, callee, call.type_args)
                    else
                        try inferGenericArgsFromBoundaryPayload(context, path, program, current_module, globals, locals, callee, call.args, contract);
                    defer context.allocator.free(resolved_args);
                    try validateBoundaryCall(context, allocator, path, program, current_module, globals, call, callee, callee.type_params, resolved_args);

                    var lowered_args: std.ArrayListUnmanaged(TypedExpr) = .empty;
                    errdefer {
                        for (lowered_args.items) |arg| arg.expr.destroy(allocator);
                        lowered_args.deinit(allocator);
                    }
                    for (call.args, callee.params) |arg, param| {
                        const expected = try parseTypeWithBindings(context, path, program, current_module, param.type_name, null, callee.type_params, resolved_args);
                        try appendOwnedLowered(allocator, &lowered_args, try lowerExpr(context, allocator, path, program, current_module, globals, locals, arg.value, expected));
                    }

                    try rejectBorrowedCallStateEscapes(context, path, program, current_module, globals, locals, call.args, callee, callee.type_params, resolved_args);
                    if (try lowerHostedThreadSpawnPrimitive(context, allocator, path, program, current_module, out, call, callee, resolved_args, lowered_args.items)) |result| {
                        lowered_args.items.len = 0;
                        lowered_args.deinit(allocator);
                        return result;
                    }
                    const concrete = try instantiateGenericFunctionFromResolvedCall(context, allocator, path, program, current_module, globals, locals, call.callee_token, callee, resolved_args, call.args, lowered_args.items);
                    defer allocator.free(concrete.arg_exprs);
                    try args.ensureUnusedCapacity(allocator, concrete.arg_exprs.len);
                    for (concrete.arg_exprs) |arg_expr| {
                        args.appendAssumeCapacity(.{ .value = arg_expr });
                    }
                    lowered_args.items.len = 0;
                    lowered_args.deinit(allocator);
                    lowered_args = .empty;

                    const owned_args = try args.toOwnedSlice(allocator);
                    out.* = .{ .call = .{
                        .intrinsic_id = intrinsic,
                        .decl_id = maybeRegisteredDeclId(context, concrete.module_name, concrete.owner, concrete.name, .function),
                        .module_name = concrete.module_name,
                        .owner = concrete.owner,
                        .callee = concrete.name,
                        .args = owned_args,
                    } };
                    try attachCheckedCallUse(context, out, concrete.return_type_id, context.function_state.active_source_decl_id, call.callee_token.offset);
                    return try makeTypedExprWithProvenance(
                        context,
                        out,
                        concrete.return_type_id,
                        concrete.return_provenance,
                    );
                }
            }

            var lowered_args: std.ArrayListUnmanaged(TypedExpr) = .empty;
            errdefer {
                for (lowered_args.items) |arg| arg.expr.destroy(allocator);
                lowered_args.deinit(allocator);
            }
            var has_contextual_arg = false;
            for (call.args) |arg| {
                switch (arg.value.*) {
                    .array_literal => |literal| {
                        if (literal.token.tag != .l_paren) has_contextual_arg = true;
                    },
                    .keyed_literal, .none, .union_case => has_contextual_arg = true,
                    .function_expr => |function| {
                        if (function.return_type == null) has_contextual_arg = true;
                        for (function.params) |param| if (param.type_name == null) {
                            has_contextual_arg = true;
                        };
                    },
                    else => {},
                }
            }
            const resolved_args = if (has_contextual_arg) blk: {
                // Infer from independent arguments and the expected return first,
                // then lower contextual arguments against the instantiated signature.
                const staged = try allocator.alloc(?TypedExpr, call.args.len);
                defer allocator.free(staged);
                @memset(staged, null);
                errdefer for (staged) |maybe_arg| if (maybe_arg) |arg| arg.expr.destroy(allocator);
                for (call.args, callee.params, staged) |arg, param, *slot| {
                    const needs_context = switch (arg.value.*) {
                        .array_literal => |literal| literal.token.tag != .l_paren,
                        .keyed_literal, .none, .union_case => true,
                        .function_expr => |function| blk_context: {
                            if (function.return_type == null) break :blk_context true;
                            for (function.params) |parameter| if (parameter.type_name == null) break :blk_context true;
                            break :blk_context false;
                        },
                        else => false,
                    };
                    if (needs_context) continue;
                    slot.* = try lowerMethodInferenceArg(context, allocator, path, program, current_module, globals, locals, arg.value, param.type_name);
                }
                const inferred = if (call.type_args.len != 0)
                    try resolveExplicitGenericArgs(context, path, program, current_module, callee, call.type_args)
                else
                    try inferGenericArgsFromCall(context, path, program, current_module, callee, staged, expected_type_id);
                errdefer context.allocator.free(inferred);
                for (call.args, callee.params, staged) |arg, param, *slot| {
                    if (slot.* != null) continue;
                    const expected = try parseTypeWithBindings(context, path, program, callee.module_name, param.type_name, null, callee.type_params, inferred);
                    slot.* = try lowerExprInContext(context, allocator, path, program, current_module, globals, locals, arg.value, expected);
                }
                try lowered_args.ensureUnusedCapacity(allocator, staged.len);
                for (staged) |*slot| {
                    lowered_args.appendAssumeCapacity(slot.*.?);
                    slot.* = null;
                }
                break :blk inferred;
            } else blk: {
                if (call.type_args.len != 0) {
                    const explicit = try resolveExplicitGenericArgs(context, path, program, current_module, callee, call.type_args);
                    errdefer context.allocator.free(explicit);
                    for (call.args, callee.params) |arg, param| {
                        const expected = try parseTypeWithBindings(context, path, program, callee.module_name, param.type_name, null, callee.type_params, explicit);
                        const lowered = try lowerExprInContext(context, allocator, path, program, current_module, globals, locals, arg.value, expected);
                        try appendOwnedLowered(allocator, &lowered_args, lowered);
                    }
                    break :blk explicit;
                }
                for (call.args, callee.params) |arg, param| {
                    try appendOwnedLowered(allocator, &lowered_args, try lowerMethodInferenceArg(context, allocator, path, program, current_module, globals, locals, arg.value, param.type_name));
                }
                break :blk try inferGenericArgsFromCall(context, path, program, current_module, callee, lowered_args.items, expected_type_id);
            };
            defer context.allocator.free(resolved_args);
            try validateBoundaryCall(context, allocator, path, program, current_module, globals, call, callee, callee.type_params, resolved_args);
            try rejectBorrowedCallStateEscapes(context, path, program, current_module, globals, locals, call.args, callee, callee.type_params, resolved_args);
            if (try lowerHostedSyncSharePrimitive(context, allocator, path, program, current_module, locals, out, call, callee, resolved_args, lowered_args.items)) |result| {
                lowered_args.items.len = 0;
                lowered_args.deinit(allocator);
                return result;
            }
            if (try lowerHostedOwnArcPrimitive(context, allocator, path, program, current_module, locals, out, call, callee, resolved_args, lowered_args.items)) |result| {
                lowered_args.items.len = 0;
                lowered_args.deinit(allocator);
                return result;
            }
            if (try lowerHostedTaskGroupSpawnPrimitive(context, allocator, path, program, out, call, callee, resolved_args, lowered_args.items)) |result| {
                lowered_args.items.len = 0;
                lowered_args.deinit(allocator);
                return result;
            }
            if (try lowerHostedTaskResultTakePrimitive(context, path, program, out, callee, resolved_args, lowered_args.items)) |result| {
                lowered_args.items.len = 0;
                lowered_args.deinit(allocator);
                return result;
            }
            // The binder a container argument supplies is projected by the call, and the
            // result stands for it before the argument list takes ownership of the parts.
            const projection_origin = try genericCallProjectionOrigin(context, callee, lowered_args.items);
            const concrete = try instantiateGenericFunctionFromResolvedCall(context, allocator, path, program, current_module, globals, locals, call.callee_token, callee, resolved_args, call.args, lowered_args.items);
            defer allocator.free(concrete.arg_exprs);
            try args.ensureUnusedCapacity(allocator, concrete.arg_exprs.len);
            for (concrete.arg_exprs) |arg_expr| {
                args.appendAssumeCapacity(.{ .value = arg_expr });
            }
            lowered_args.items.len = 0;
            lowered_args.deinit(allocator);
            lowered_args = .empty;

            const owned_args = try args.toOwnedSlice(allocator);
            out.* = .{ .call = .{
                .intrinsic_id = intrinsics.resolveDeclaration(callee.module_name, callee.owner, callee.name),
                .decl_id = maybeRegisteredDeclId(context, concrete.module_name, concrete.owner, concrete.name, .function),
                .module_name = concrete.module_name,
                .owner = concrete.owner,
                .callee = concrete.name,
                .args = owned_args,
            } };
            try attachCheckedCallUse(context, out, concrete.return_type_id, context.function_state.active_source_decl_id, call.callee_token.offset);
            var result = try makeTypedExprWithProvenance(
                context,
                out,
                concrete.return_type_id,
                concrete.return_provenance,
            );
            if (result.generic_origin == null) result.generic_origin = projection_origin;
            return result;
        }

        pub fn lowerExplicitIntrinsicCall(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            call: ast.Call,
            callee: ast.Function,
        ) SemaError!TypedExpr {
            const intrinsic_id = intrinsics.resolveExplicit(callee.intrinsic_name.?) orelse return SemaError.SemanticFailed;
            switch (intrinsic_id) {
                .value_eq => {},
                else => unreachable,
            }

            var lowered_args: std.ArrayListUnmanaged(TypedExpr) = .empty;
            errdefer {
                for (lowered_args.items) |arg| arg.expr.destroy(allocator);
                lowered_args.deinit(allocator);
            }
            for (call.args) |arg| {
                try appendOwnedLowered(allocator, &lowered_args, try lowerExpr(context, allocator, path, program, current_module, globals, locals, arg.value, null));
            }
            if (lowered_args.items.len != 2) return SemaError.SemanticFailed;
            const explicit_args = if (call.type_args.len != 0)
                try resolveExplicitGenericArgs(context, path, program, current_module, callee, call.type_args)
            else
                null;
            defer if (explicit_args) |args| context.allocator.free(args);
            const value_type = if (explicit_args) |args| blk: {
                if (args.len != 1 or args[0] != .type) return SemaError.SemanticFailed;
                break :blk args[0].type;
            } else lowered_args.items[0].type_id;
            try type_resolution.expectEqualitySupported(canonical.displayContext(context), &context.diagnostic_context, path, call.callee_token, value_type);
            for (lowered_args.items, call.args) |arg, original| {
                try expectType(context, path, firstExprToken(original.value), value_type, arg.type_id);
            }

            const left = lowered_args.items[0].expr;
            const right = lowered_args.items[1].expr;
            lowered_args.items.len = 0;
            lowered_args.deinit(allocator);
            out.* = .{ .binary = .{
                .op = .eq,
                .left = left,
                .right = right,
            } };
            return makeTypedExprFromId(out, try canonicalPrimitiveTypeId(context, .bool));
        }

        pub fn lowerIndirectCall(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            call: ast.Call,
            callee_local: LocalBinding,
        ) SemaError!TypedExpr {
            if (call.type_args.len != 0) {
                try context.diagnostic_context.emitToken(path, call.callee_token, "function pointer `{s}` does not accept explicit type arguments", .{call.callee});
                return SemaError.SemanticFailed;
            }
            const function_type = switch (canonicalTypeNode(context, callee_local.type_id).*) {
                .callable => |callable| callable,
                else => return error.SemanticFailed,
            };
            const return_type_id = function_type.return_type;
            if (function_type.params.len != call.args.len) {
                try context.diagnostic_context.emitToken(path, call.callee_token, "function pointer `{s}` expects {d} args, got {d}", .{ call.callee, function_type.params.len, call.args.len });
                return SemaError.SemanticFailed;
            }
            if (try typeMayCarryBorrowedProvenance(context, path, program, current_module, return_type_id)) {
                try context.diagnostic_context.emitToken(path, call.callee_token, "indirect callable `{s}` cannot return borrowed data without a checked provenance contract", .{call.callee});
                return SemaError.SemanticFailed;
            }

            var args: std.ArrayListUnmanaged(sir.CallArg) = .empty;
            errdefer {
                for (args.items) |arg| arg.deinit(allocator);
                args.deinit(allocator);
            }
            for (call.args, function_type.params) |arg, expected_id| {
                try appendOwnedLowered(allocator, &args, try lowerCallArg(
                    context,
                    allocator,
                    path,
                    program,
                    current_module,
                    globals,
                    locals,
                    arg,
                    expected_id,
                    null,
                ));
            }

            const callee_expr = try allocator.create(sir.Expr);
            errdefer callee_expr.destroy(allocator);
            callee_expr.* = .{ .local = call.callee };
            var callee_typed = makeTypedExprFromId(callee_expr, callee_local.type_id);
            callee_typed.generic_shape = callee_local.generic_shape;
            callee_typed.generic_origin = callee_local.generic_origin;
            try finalizeAndRecordExprSemantics(context, path, program, current_module, &callee_typed);
            if (callee_local.binding_id) |binding_id| try recordGeneratedBindingRoot(context, callee_expr, binding_id, false);
            // `toOwnedSlice` is hoisted out of the union literal so a failure leaves
            // `out` neutral and the errdefer above the only owner of `callee_expr`.
            const owned_args = try args.toOwnedSlice(allocator);
            args = .empty;
            out.* = .{ .indirect_call = .{
                .callee = callee_expr,
                .args = owned_args,
                .return_type_id = return_type_id,
                .is_arrow_callable = callee_local.kind(context) == .arrow_callable,
            } };
            return .{
                .expr = out,
                .type_id = return_type_id,
                .provenance = .none(),
            };
        }

        pub fn lowerFunctionExpr(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            function_expr: ast.FunctionExpr,
            expected_type_id: ?semantic_types.TypeId,
        ) SemaError!TypedExpr {
            const function_type_id = if (expected_type_id) |expected| blk: {
                if (canonicalTypeKind(context, expected) != .function and canonicalTypeKind(context, expected) != .arrow_callable) {
                    try context.diagnostic_context.emitToken(path, function_expr.token, "function expression requires an expected function pointer or non-escaping callable type", .{});
                    return SemaError.SemanticFailed;
                }
                break :blk expected;
            } else try inferExplicitFunctionExprType(context, allocator, path, program, current_module, function_expr);
            const function_type = canonicalTypeNode(context, function_type_id).callable;

            if (function_type.params.len != function_expr.params.len) {
                try context.diagnostic_context.emitToken(path, function_expr.token, "function expression expects {d} parameters from context, got {d}", .{ function_type.params.len, function_expr.params.len });
                return SemaError.SemanticFailed;
            }
            const expected_cc = functionTypeCallingConvention(context, function_type_id);
            if (expected_cc != function_expr.calling_convention) {
                const display = try formatCanonicalTypeDisplay(context, function_type_id);
                defer allocator.free(display);
                try context.diagnostic_context.emitToken(path, function_expr.token, "function expression calling convention does not match expected type `{s}`", .{display});
                return SemaError.SemanticFailed;
            }
            if (function_expr.return_type) |type_name| {
                const explicit_return = try parseCanonicalType(context, path, program, current_module, type_name);
                const expected_return_id = function_type.return_type;
                if (explicit_return != expected_return_id) {
                    const explicit_display = try formatCanonicalTypeDisplay(context, explicit_return);
                    defer allocator.free(explicit_display);
                    const expected_display = try formatCanonicalTypeDisplay(context, expected_return_id);
                    defer allocator.free(expected_display);
                    try context.diagnostic_context.emitToken(path, type_name.token, "function expression return type `{s}` does not match expected `{s}`", .{
                        explicit_display,
                        expected_display,
                    });
                    return SemaError.SemanticFailed;
                }
            }

            const name = try std.fmt.allocPrint(allocator, "{s}{d}", .{ generated_names.anonymous_function_prefix, context.anonymous_function_counter });
            context.anonymous_function_counter += 1;
            try context.output.generated_strings.append(allocator, name);
            const decl_id = (try registerGeneratedDecl(context, current_module, null, name, .function)) orelse
                return error.SemanticFailed;
            var lowered = try lowerAnonymousFunction(
                context,
                allocator,
                path,
                program,
                current_module,
                globals,
                locals,
                function_expr,
                function_type_id,
                name,
                decl_id,
            );
            errdefer allocator.free(lowered.captures);
            var owns_function = true;
            errdefer if (owns_function) lowered.function.deinit(allocator);
            lowered.function.decl_id = decl_id;
            try context.generic.instantiated_functions.append(allocator, lowered.function);
            owns_function = false;

            if (function_type.kind == .arrow) {
                const captures = try allocator.alloc(*sir.Expr, lowered.captures.len);
                var initialized_captures: usize = 0;
                errdefer {
                    for (captures[0..initialized_captures]) |capture| capture.destroy(allocator);
                    allocator.free(captures);
                }
                for (lowered.captures, captures) |capture, *dst| {
                    const expr = try allocator.create(sir.Expr);
                    errdefer expr.destroy(allocator);
                    expr.* = .{ .local = capture.name };
                    var capture_typed = makeTypedExprFromId(expr, capture.type_id);
                    try finalizeAndRecordExprSemantics(context, path, program, current_module, &capture_typed);
                    if (capture.binding_id) |binding_id| try recordGeneratedBindingRoot(context, expr, binding_id, false);
                    dst.* = expr;
                    initialized_captures += 1;
                }
                const env_type_name = lowered.env_type_name orelse return SemaError.SemanticFailed;
                const env_decl_id = lowered.env_decl_id orelse return SemaError.SemanticFailed;
                allocator.free(lowered.captures);
                out.* = .{ .closure = .{
                    .function = .{
                        .decl_id = decl_id,
                        .module_name = current_module,
                        .owner = null,
                        .name = name,
                    },
                    .env_type_name = env_type_name,
                    .env_decl_id = env_decl_id,
                    .captures = captures,
                } };
            } else {
                allocator.free(lowered.captures);
                out.* = .{ .function_ref = .{
                    .decl_id = decl_id,
                    .module_name = current_module,
                    .owner = null,
                    .name = name,
                } };
            }
            return makeTypedExprFromId(out, function_type_id);
        }

        pub fn lowerBuiltinStringFromCall(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            call: ast.Call,
        ) SemaError!TypedExpr {
            if (call.type_args.len != 0) {
                try context.diagnostic_context.emitToken(path, call.callee_token, "string.from does not accept explicit type arguments", .{});
                return SemaError.SemanticFailed;
            }
            if (call.args.len != 1) {
                try context.diagnostic_context.emitToken(path, call.callee_token, "string.from expects one argument", .{});
                return SemaError.SemanticFailed;
            }

            const bytes_type = try canonicalSliceTypeId(context, try canonicalIntegerTypeId(context, "u8"), true);
            const bytes = try lowerExpr(context, allocator, path, program, current_module, globals, locals, call.args[0].value, bytes_type);
            errdefer bytes.expr.destroy(allocator);
            try expectType(context, path, firstExprToken(call.args[0].value), bytes_type, bytes.type_id);
            out.* = .{ .string_from = bytes.expr };
            return withIntrinsic(makeTypedExprFromId(out, try canonicalPrimitiveTypeId(context, .string)), .string_from);
        }

        pub fn lowerBuiltinAssertCall(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            call: ast.Call,
        ) SemaError!TypedExpr {
            if (call.type_args.len != 0) {
                try context.diagnostic_context.emitToken(path, call.callee_token, "builtin `{s}` does not accept explicit type arguments", .{call.callee});
                return SemaError.SemanticFailed;
            }
            if (call.args.len != 1) {
                try context.diagnostic_context.emitToken(path, call.callee_token, "builtin `{s}` expects exactly one argument", .{call.callee});
                return SemaError.SemanticFailed;
            }

            const condition = try lowerExpr(context, allocator, path, program, current_module, globals, locals, call.args[0].value, try canonicalPrimitiveTypeId(context, .bool));
            if (condition.kind(context) != .bool) {
                try context.diagnostic_context.emitToken(path, firstExprToken(call.args[0].value), "builtin `{s}` expects a bool condition", .{call.callee});
                condition.expr.destroy(allocator);
                return SemaError.SemanticFailed;
            }

            out.* = .{ .test_assert = condition.expr };
            return withIntrinsic(makeTypedExprFromId(out, try canonicalPrimitiveTypeId(context, .void)), .builtin_assert);
        }

        pub fn lowerBuiltinPrintCall(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            call: ast.Call,
        ) SemaError!TypedExpr {
            if (call.type_args.len != 0) {
                try context.diagnostic_context.emitToken(path, call.callee_token, "builtin `{s}` does not accept explicit type arguments", .{call.callee});
                return SemaError.SemanticFailed;
            }
            if (call.args.len != 1) {
                try context.diagnostic_context.emitToken(path, call.callee_token, "builtin `{s}` expects exactly one argument; use interpolation for formatted output", .{call.callee});
                return SemaError.SemanticFailed;
            }

            const value = try lowerExpr(context, allocator, path, program, current_module, globals, locals, call.args[0].value, null);
            switch (value.kind(context)) {
                .string, .bool, .int => {},
                else => {
                    try context.diagnostic_context.emitToken(path, firstExprToken(call.args[0].value), "builtin `{s}` accepts only string, bool, and integer values", .{call.callee});
                    value.expr.destroy(allocator);
                    return SemaError.SemanticFailed;
                },
            }

            const parts = try allocator.alloc(sir.BuiltinPrintPart, 1);
            errdefer allocator.free(parts);
            // The printed value reaches one of the prelude print helpers. Record that
            // helper's declaration identity here so lowering emits the call from the
            // record instead of searching the module for a name. A synthetic SIR that
            // never declares the prelude leaves the identity absent, and lowering then
            // rejects the print as a shape gap rather than guessing a helper.
            const helper_declaration_id = switch (value.kind(context)) {
                .string => maybeRegisteredDeclId(context, package_manifest.prelude_module_name, null, "print_string", .function),
                .bool => maybeRegisteredDeclId(context, package_manifest.prelude_module_name, null, "print_bool", .function),
                .int => maybeRegisteredDeclId(context, package_manifest.prelude_module_name, null, "print_int", .function),
                else => null,
            };
            const append_newline = std.mem.eql(u8, call.callee, "println");
            parts[0] = .{ .value = .{ .expr = value.expr, .format = .direct, .helper_declaration_id = helper_declaration_id } };
            out.* = .{ .builtin_print = .{
                .parts = parts,
                .append_newline = append_newline,
                .newline_helper_declaration_id = if (append_newline) maybeRegisteredDeclId(context, package_manifest.prelude_module_name, null, "print_newline", .function) else null,
            } };
            return withIntrinsic(
                makeTypedExprFromId(out, try canonicalPrimitiveTypeId(context, .void)),
                if (out.builtin_print.append_newline) .builtin_println else .builtin_print,
            );
        }

        pub fn lowerInterpolatedString(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            interpolated: ast.InterpolatedString,
        ) SemaError!TypedExpr {
            var parts = std.ArrayListUnmanaged(sir.BuiltinPrintPart).empty;
            errdefer {
                for (parts.items) |part| part.deinit(allocator);
                parts.deinit(allocator);
            }

            for (interpolated.parts) |part| switch (part) {
                .literal => |text| {
                    if (text.len != 0) {
                        try parts.append(allocator, .{ .literal = try allocator.dupe(u8, text) });
                    }
                },
                .hole => |hole| {
                    const projection = try buildInterpolationProjectionExpr(allocator, hole);
                    defer projection.destroy(allocator);

                    const lowered = try lowerExpr(context, allocator, path, program, current_module, globals, locals, projection, null);
                    try recordLoweredOperationUse(context, "format", hole.token, lowered);

                    const format = interpolationFormatToDebugFormat(hole.format);
                    switch (lowered.kind(context)) {
                        .string, .bool => if (format != .direct) {
                            try context.diagnostic_context.emitToken(path, hole.token, "interpolation format specifiers require an integer value", .{});
                            lowered.expr.destroy(allocator);
                            return SemaError.SemanticFailed;
                        },
                        .int => {},
                        else => {
                            const actual_name = try formatCanonicalTypeDisplay(context, lowered.type_id);
                            defer allocator.free(actual_name);
                            try context.diagnostic_context.emitToken(path, hole.token, "cannot interpolate value of type {s}; use a string, bool, or integer value", .{actual_name});
                            lowered.expr.destroy(allocator);
                            return SemaError.SemanticFailed;
                        },
                    }

                    try parts.append(allocator, .{ .value = .{ .expr = lowered.expr, .format = format } });
                },
            };

            out.* = .{ .interpolated_string = try parts.toOwnedSlice(allocator) };
            return makeTypedExprFromId(out, try canonicalPrimitiveTypeId(context, .string));
        }

        pub fn lowerMethodInferenceArg(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            expr: *ast.Expr,
            pattern: ast.TypeName,
        ) SemaError!TypedExpr {
            if (pattern.is_ref and expr.* == .name) {
                if (findLocal(locals, expr.name.text)) |local| {
                    if (local.kind(context) == .ref) {
                        const out = try allocator.create(sir.Expr);
                        errdefer allocator.destroy(out);
                        out.* = .{ .ref_alias_local = expr.name.text };
                        var typed = try makeTypedExprWithProvenance(context, out, local.type_id, local.provenance);
                        typed.generic_shape = local.generic_shape;
                        typed.generic_origin = local.generic_origin;
                        try finalizeAndRecordExprSemantics(context, path, program, current_module, &typed);
                        try recordLoweredPlaceIdentity(context, allocator, path, program, current_module, globals, locals, expr, out);
                        return typed;
                    }
                }
            }
            if (pattern.is_function and expr.* == .name) {
                const name = expr.name;
                if (findLocal(locals, name.text) == null) {
                    if (findAstFunction(context, program, current_module, null, name.text)) |resolved| {
                        if (resolved.decl.type_params.len == 0) {
                            const ty = try functionDeclType(context, allocator, path, program, resolved.decl);
                            const out = try allocator.create(sir.Expr);
                            errdefer allocator.destroy(out);
                            const owned_decl_id = try registeredDeclId(context, resolved.decl.module_name, resolved.decl.owner, resolved.decl.name, .function);
                            out.* = .{ .function_ref = .{
                                .decl_id = owned_decl_id,
                                .module_name = resolved.decl.module_name,
                                .owner = resolved.decl.owner,
                                .name = resolved.decl.name,
                            } };
                            var typed = makeTypedExprFromId(out, ty);
                            try finalizeAndRecordExprSemantics(context, path, program, current_module, &typed);
                            return typed;
                        }
                    }
                }
            }
            return lowerExpr(context, allocator, path, program, current_module, globals, locals, expr, null);
        }

        pub fn lowerGenericBinderMethodCall(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            call: ast.MethodCall,
            object: TypedExpr,
            checked_authority: ?CheckedMethodAuthority,
            binder_type: semantic_types.TypeId,
            qualified_protocol: ?identity.DeclId,
            owns_object_expr: *bool,
        ) SemaError!TypedExpr {
            const authority = checked_authority orelse try genericBinderMethodAuthority(context, path, program, call, binder_type, qualified_protocol);
            if (authority == null) {
                try context.diagnostic_context.emitToken(path, call.method_token, "type has no method `{s}`", .{call.method});
                return SemaError.SemanticFailed;
            }
            const protocol_decl = try protocols.declarationForId(protocols.contextFromSession(SemaContext, context), program, authority.?.protocol);
            const method = try protocols.methodOf(protocol_decl, call.method);
            try expectNoExplicitMethodTypeArgs(context, path, call);
            const contract_index = try genericBinderContractFunction(context, allocator, path, program, binder_type, protocol_decl, authority.?.protocol, method);
            const contract = context.generic.generic_contract_functions.items[contract_index];
            const contract_decl_id = contract.decl_id orelse return error.SemanticFailed;
            const contract_return_type = contract.return_type_id orelse return error.SemanticFailed;
            if (call.args.len + 1 != contract.params.len) {
                try context.diagnostic_context.emitToken(path, call.method_token, "method `{s}` expects {d} arguments", .{ call.method, contract.params.len - 1 });
                return SemaError.SemanticFailed;
            }
            // The binder's contract borrows the receiver place, exactly as a concrete
            // witness method does: the contract's `Self` parameter is a reference, so
            // a value view of an addressable place is handed over as a borrow.
            const self_type = contract.params[0].type_id orelse return error.SemanticFailed;
            var receiver_expr: *sir.Expr = object.expr;
            var borrowed_receiver: ?*sir.Expr = null;
            errdefer if (borrowed_receiver) |expr| expr.destroy(allocator);
            if (canonicalTypeKind(context, self_type) == .ref and object.kind(context) != .ref and
                type_resolution.containsDefinitionSiteBinder(canonicalTypeInterner(context), object.type_id))
            {
                // A deferred definition-site receiver (the payload of a `try`, an index
                // into a binder container) is not a place the trial body can borrow. The
                // use is still recorded with its checked authority, and each
                // specialization re-lowers the call against the concrete receiver place.
                // The receiver expression stays owned here until the argument list takes
                // it, so a failure before that transfer releases it.
            } else if (canonicalTypeKind(context, self_type) == .ref and object.kind(context) != .ref) {
                const borrowed = try lowerBorrowedReceiver(context, allocator, path, program, current_module, globals, locals, call.object, object.expr, object.type_id, owns_object_expr, true);
                borrowed_receiver = borrowed;
                var borrowed_typed = makeTypedExprFromId(borrowed, self_type);
                try finalizeAndRecordExprSemantics(context, path, program, current_module, &borrowed_typed);
                try recordLoweredPlaceIdentity(context, allocator, path, program, current_module, globals, locals, call.object, borrowed);
                receiver_expr = borrowed;
            }
            var args: std.ArrayListUnmanaged(sir.CallArg) = .empty;
            errdefer {
                for (args.items) |arg| arg.deinit(allocator);
                args.deinit(allocator);
            }
            try args.append(allocator, .{ .value = receiver_expr });
            // The argument list now owns the receiver expression.
            borrowed_receiver = null;
            owns_object_expr.* = false;
            for (call.args, 0..) |arg, index| {
                const expected = contract.params[index + 1].type_id orelse return error.SemanticFailed;
                // Binder arguments are lowered like ordinary call arguments so a
                // ref-typed local passed to a `&const` contract parameter reborrows
                // instead of dereferencing into an owned value.
                const lowered_arg = try lowerCallArg(context, allocator, path, program, current_module, globals, locals, arg, expected, null);
                try args.append(allocator, .{ .value = lowered_arg.value });
            }
            var method_use = try checkedMethodUse(context, call, authority, contract_decl_id, contract_return_type, null);
            errdefer if (method_use != null and method_use.?.substitution.len != 0) allocator.free(method_use.?.substitution);
            var owned_args = try args.toOwnedSlice(allocator);
            errdefer allocator.free(owned_args);
            out.* = .{ .call = .{
                .decl_id = contract_decl_id,
                .checked_method_use = method_use,
                .module_name = protocol_decl.module_name,
                .owner = protocol_decl.name,
                .callee = contract.name,
                .args = owned_args,
            } };
            // The call node owns the argument slice from here, so neutralise the local
            // before any step that can fail: the node's release must be the only owner.
            owned_args = &.{};
            if (method_use == null) try attachCheckedCallUse(context, out, contract_return_type, context.function_state.active_source_decl_id, call.method_token.offset);
            method_use = null;
            var result = try makeTypedExprWithProvenance(context, out, contract_return_type, object.provenance);
            if (method.return_type) |return_type| {
                // `Self.Item` stands for what the binder projects out of itself: the
                // contract's return type names only the binder, so the lowered call
                // records the projection the checked body already proved.
                if (protocols.protocolAssociatedProjection(protocol_decl, return_type) != null) {
                    result.generic_shape = try context.generic.shapes.project(context.allocator, object.generic_shape);
                    result.generic_origin = projectedOrigin(object.generic_origin);
                }
            }
            return result;
        }

        pub fn lowerMethodCall(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            call: ast.MethodCall,
        ) SemaError!TypedExpr {
            return lowerMethodCallInternal(context, allocator, path, program, current_module, globals, locals, out, call, null);
        }

        pub fn lowerMethodCallInternal(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            call: ast.MethodCall,
            qualified_protocol: ?identity.DeclId,
        ) SemaError!TypedExpr {
            return lowerMethodCallWithReceiver(context, allocator, path, program, current_module, globals, locals, out, call, qualified_protocol, null);
        }

        pub fn lowerMethodCallWithReceiver(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            call: ast.MethodCall,
            qualified_protocol: ?identity.DeclId,
            prelowered_receiver: ?TypedExpr,
        ) SemaError!TypedExpr {
            if (call.object.* == .name) {
                const object_name = call.object.name.text;
                if (findLocal(locals, object_name)) |local| {
                    if (local.is_failure_view) {
                        const site_file = std.mem.eql(u8, call.method, "site_file");
                        if (!site_file and !std.mem.eql(u8, call.method, "site")) {
                            try context.diagnostic_context.emitToken(path, call.method_token, "unknown failure detail method `{s}`", .{call.method});
                            return SemaError.SemanticFailed;
                        }
                        if (call.type_args.len != 0 or call.args.len != 1) {
                            try context.diagnostic_context.emitToken(path, call.method_token, "failure.{s} expects one index and no type arguments", .{call.method});
                            return SemaError.SemanticFailed;
                        }
                        const index_type = try canonicalIntegerTypeId(context, "i64");
                        const index = try lowerExpr(context, allocator, path, program, current_module, globals, locals, call.args[0].value, index_type);
                        errdefer index.expr.destroy(allocator);
                        try expectType(context, path, firstExprToken(call.args[0].value), index_type, index.type_id);
                        out.* = .{ .failure_detail = .{
                            .binding_id = local.binding_id orelse return SemaError.SemanticFailed,
                            .field = if (site_file) .site_file else .site,
                            .index = index.expr,
                        } };
                        const site_type = try canonicalOptionalTypeId(context, if (site_file)
                            try canonicalPrimitiveTypeId(context, .string)
                        else
                            try canonicalIntegerTypeId(context, "u32"));
                        return makeTypedExprWithProvenance(context, out, site_type, .none());
                    }
                }
                if (findImportedModulePath(program, current_module, object_name)) |module_name| {
                    const module_call = ast.Call{
                        .owner = module_name,
                        .callee = call.method,
                        .callee_token = call.method_token,
                        .type_args = call.type_args,
                        .args = call.args,
                    };
                    return lowerCall(context, allocator, path, program, current_module, globals, locals, out, module_call, null);
                }
                if (std.mem.eql(u8, object_name, "resource") and findLocal(locals, object_name) == null) {
                    if (std.mem.eql(u8, call.method, "leak")) {
                        if (call.type_args.len != 0) {
                            try context.diagnostic_context.emitToken(path, call.method_token, "resource.leak does not accept explicit type arguments", .{});
                            return SemaError.SemanticFailed;
                        }
                        if (call.args.len != 1) {
                            try context.diagnostic_context.emitToken(path, call.method_token, "resource.leak expects one owned value", .{});
                            return SemaError.SemanticFailed;
                        }
                        return lowerMethodCallInternal(context, allocator, path, program, current_module, globals, locals, out, .{
                            .object = call.args[0].value,
                            .method = "leak",
                            .method_token = call.method_token,
                            .type_args = &.{},
                            .args = &.{},
                        }, null);
                    }
                    if (std.mem.eql(u8, call.method, "from_raw")) {
                        const initializing_local = context.function_state.resource_from_raw_initializer;
                        if (!initializing_local) {
                            try context.diagnostic_context.emitToken(path, call.method_token, "resource.from_raw must directly initialize an owning local", .{});
                            return SemaError.SemanticFailed;
                        }
                        context.function_state.resource_from_raw_initializer = false;
                        defer context.function_state.resource_from_raw_initializer = initializing_local;
                        if (call.type_args.len != 0) {
                            try context.diagnostic_context.emitToken(path, call.method_token, "resource.from_raw does not accept explicit type arguments", .{});
                            return SemaError.SemanticFailed;
                        }
                        if (call.args.len != 1) {
                            try context.diagnostic_context.emitToken(path, call.method_token, "resource.from_raw expects one raw pointer", .{});
                            return SemaError.SemanticFailed;
                        }
                        const raw = try lowerExpr(context, allocator, path, program, current_module, globals, locals, call.args[0].value, null);
                        errdefer raw.expr.destroy(allocator);
                        const raw_type = canonicalTypeNode(context, raw.type_id).*;
                        if (raw_type != .raw) {
                            try context.diagnostic_context.emitToken(path, firstExprToken(call.args[0].value), "resource.from_raw expects a non-optional `*T` raw pointer", .{});
                            return SemaError.SemanticFailed;
                        }
                        const pointee = raw_type.raw.target;
                        if (canonicalTypeKind(context, pointee) == .function or
                            canonicalTypeKind(context, pointee) == .arrow_callable)
                        {
                            try context.diagnostic_context.emitToken(path, firstExprToken(call.args[0].value), "resource.from_raw cannot reconstruct a callable value", .{});
                            return SemaError.SemanticFailed;
                        }
                        if (call.args[0].value.* == .name) {
                            try markLocalHandedOff(context, path, @constCast(locals), call.args[0].value.name);
                        }
                        out.* = .{ .from_raw = .{
                            .expr = raw.expr,
                            .is_volatile = raw_type.raw.is_volatile,
                        } };
                        const owned_type = try canonicalOwnedTypeId(context, pointee);
                        return withIntrinsic(
                            try makeTypedExprWithProvenance(context, out, owned_type, .none()),
                            .resource_from_raw,
                        );
                    }
                }
            }

            const object = prelowered_receiver orelse try lowerExpr(context, allocator, path, program, current_module, globals, locals, call.object, null);
            var owns_object_expr = true;
            errdefer if (owns_object_expr) object.expr.destroy(allocator);
            var receiver_origins: std.ArrayListUnmanaged(GenericReceiverOrigin) = .empty;
            defer receiver_origins.deinit(allocator);
            try receiverOrigins(allocator, object, &receiver_origins);
            const shape_protocol = try declaredGenericMethodForOrigins(context, path, program, receiver_origins.items, call, qualified_protocol);
            var checked_authority = try checkedProtocolForMethodUse(context, path, current_module, call);
            if (shape_protocol != null and checked_authority == null and context.function_state.active_source_decl_id != null and receiver_origins.items.len != 0) {
                // The use is recorded by the body that lowers it, so the authority a
                // specialization reads is the one the definition site established.
                checked_authority = try recordLoweredMethodUse(context, program, call, object, shape_protocol.?);
                if (checked_authority == null) {
                    try context.diagnostic_context.emitToken(path, call.method_token, "generic method `{s}` is missing its checked protocol authority", .{call.method});
                    return error.SemanticFailed;
                }
            }
            if (shape_protocol != null and checked_authority != null and shape_protocol.? != checked_authority.?.protocol) {
                try context.diagnostic_context.emitToken(path, call.method_token, "generic method `{s}` has inconsistent declared protocol authority", .{call.method});
                return error.SemanticFailed;
            }
            const forced_protocol = if (checked_authority) |authority| authority.protocol else shape_protocol;
            const forced_method = if (checked_authority) |authority| authority.method else null;
            const builtin_method_id = if (type_resolution.intrinsicReceiverForType(typeConstructionContext(context), object.type_id)) |receiver|
                intrinsics.resolveMethod(receiver, call.method)
            else
                null;
            if (qualified_protocol) |protocol_id| {
                const dense_type = if (object.kind(context) == .ref) canonicalRefTarget(context, object.type_id) else object.type_id;
                if (canonicalTypeKind(context, dense_type) == .dense_array and std.mem.eql(u8, call.method, "clone")) {
                    for (program.protocols) |protocol_decl| {
                        if (try registeredDeclId(context, protocol_decl.module_name, null, protocol_decl.name, .protocol) != protocol_id) continue;
                        if (!try protocols.isTrustedDenseCloneConformance(SemaContext, typeIsOwnedForProtocol, context, path, program, dense_type, .{ .id = protocol_id, .decl = protocol_decl })) break;
                        try expectNoExplicitMethodTypeArgs(context, path, call);
                        if (call.args.len != 0) {
                            try context.diagnostic_context.emitToken(path, call.method_token, "Clone.clone expects no arguments after its receiver", .{});
                            return SemaError.SemanticFailed;
                        }
                        owns_object_expr = false;
                        const source_expr = if (object.kind(context) == .ref) blk: {
                            const loaded = try allocator.create(sir.Expr);
                            loaded.* = .{ .ref_load = object.expr };
                            var loaded_typed = makeTypedExprFromIdWithProvenanceAndValueSemantics(
                                loaded,
                                dense_type,
                                object.provenance,
                                projectedReadValueSemantics(
                                    try typeHasStorageLifetime(context, path, program, dense_type),
                                    try typeMayCarryBorrowedProvenance(context, path, program, current_module, dense_type),
                                ),
                            );
                            try finalizeAndRecordExprSemantics(context, path, program, current_module, &loaded_typed);
                            break :blk loaded;
                        } else object.expr;
                        out.* = .{ .unary = .{ .op = .copy_list, .expr = source_expr } };
                        return withIntrinsic(makeTypedExprFromIdWithProvenance(
                            out,
                            dense_type,
                            try propagatedProvenanceForTypeId(context, path, program, current_module, dense_type, object.provenance),
                        ), .sequence_clone);
                    }
                }
            }
            if (builtin_method_id == .sequence_clone) {
                try expectNoExplicitMethodTypeArgs(context, path, call);
                if (call.args.len != 0) {
                    try context.diagnostic_context.emitToken(path, call.method_token, "[:].clone expects no arguments", .{});
                    return SemaError.SemanticFailed;
                }
                owns_object_expr = false;
                out.* = .{ .unary = .{
                    .op = .copy_list,
                    .expr = object.expr,
                } };
                return withIntrinsic(makeTypedExprFromIdWithProvenance(
                    out,
                    object.type_id,
                    try propagatedProvenanceForTypeId(context, path, program, current_module, object.type_id, object.provenance),
                ), builtin_method_id.?);
            }
            if (builtin_method_id == .string_len or builtin_method_id == .sequence_len or builtin_method_id == .sparse_len or builtin_method_id == .slice_len) {
                if (type_resolution.typeBuiltinLenMethod(typeConstructionContext(context), object.type_id)) |method_builtin| {
                    try expectNoExplicitMethodTypeArgs(context, path, call);
                    try expectZeroArgLenMethod(context, path, call, method_builtin.owner_name);
                    const result = try lowerBuiltinLenMethodCall(context, out, method_builtin.kind, object.expr);
                    owns_object_expr = false;
                    return result;
                }
            }
            if (builtin_method_id == .sequence_clear or builtin_method_id == .sparse_clear) {
                if (type_resolution.typeBuiltinClearMethod(typeConstructionContext(context), object.type_id)) |method_builtin| {
                    try expectNoExplicitMethodTypeArgs(context, path, call);
                    try expectZeroArgClearMethod(context, path, call, method_builtin.owner_name);
                    try prepareMutableContainerMethod(context, path, program, current_module, globals, locals, call.object, object.type_id, method_builtin.receiver_name, call.method_token, method_builtin.mutation_action);
                    const result = try lowerBuiltinClearMethodCall(context, out, method_builtin.kind, object.expr);
                    owns_object_expr = false;
                    return result;
                }
            }
            if (builtin_method_id == .sparse_contains_index) {
                const method_builtin = (try type_resolution.typeBuiltinContainsMethod(typeConstructionContext(context), object.type_id)) orelse unreachable;
                try expectNoExplicitMethodTypeArgs(context, path, call);
                try expectOneArgMethod(context, path, call, method_builtin.owner_name, method_builtin.method_name);
                const arg_type = method_builtin.arg_type_id;
                const value = try lowerExpr(context, allocator, path, program, current_module, globals, locals, call.args[0].value, arg_type);
                errdefer value.expr.destroy(allocator);
                try expectType(context, path, firstExprToken(call.args[0].value), arg_type, value.type_id);
                const result = try lowerBuiltinContainsMethodCall(context, out, method_builtin.kind, object.expr, value.expr);
                owns_object_expr = false;
                return result;
            }
            if (builtin_method_id == .sequence_push) {
                const method_builtin = (try type_resolution.typeBuiltinInsertMethod(typeConstructionContext(context), object.type_id)) orelse unreachable;
                try expectNoExplicitMethodTypeArgs(context, path, call);
                const result = try lowerBuiltinInsertMethodCall(context, allocator, path, program, current_module, globals, locals, out, call, object, method_builtin);
                owns_object_expr = false;
                return result;
            }
            if (builtin_method_id == .sequence_reserve) {
                const method_builtin = type_resolution.typeBuiltinReserveMethod(typeConstructionContext(context), object.type_id) orelse unreachable;
                try expectNoExplicitMethodTypeArgs(context, path, call);
                const result = try lowerBuiltinReserveMethodCall(context, allocator, path, program, current_module, globals, locals, out, call, object, method_builtin);
                owns_object_expr = false;
                return result;
            }
            if (builtin_method_id == .sequence_pop) {
                const method_builtin = (try type_resolution.typeBuiltinPopMethod(typeConstructionContext(context), object.type_id)) orelse unreachable;
                try expectNoExplicitMethodTypeArgs(context, path, call);
                const result = try lowerBuiltinPopMethodCall(context, path, program, current_module, globals, locals, out, call, object, method_builtin);
                owns_object_expr = false;
                return result;
            }
            if (object.kind(context) == .string and std.mem.eql(u8, call.method, "clone")) {
                const resolved = try protocols.resolveProtocolMethodForType(SemaContext, context, path, program, object.type_id, call.method, call.method_token, qualified_protocol, null);
                if (resolved) |method| {
                    if (method.impl_decl) |impl_decl| {
                        if (std.mem.eql(u8, impl_decl.protocol_name.name, "Clone")) {
                            try expectNoExplicitMethodTypeArgs(context, path, call);
                            if (call.args.len != 0) {
                                try context.diagnostic_context.emitToken(path, call.method_token, "method `clone` expects 0 args after self, got {d}", .{call.args.len});
                                return SemaError.SemanticFailed;
                            }
                            const bytes_expr = try allocator.create(sir.Expr);
                            bytes_expr.* = .{ .string_bytes = object.expr };
                            owns_object_expr = false;
                            var owns_bytes_expr = true;
                            errdefer if (owns_bytes_expr) bytes_expr.destroy(allocator);
                            const bytes_type = try canonicalSliceTypeId(context, try canonicalIntegerTypeId(context, "u8"), true);
                            var bytes_typed = withIntrinsic(
                                makeTypedExprFromIdWithProvenance(bytes_expr, bytes_type, try sourceViewProvenance(context, path, program, current_module, globals, locals, call.object)),
                                .string_bytes,
                            );
                            try finalizeAndRecordExprSemantics(context, path, program, current_module, &bytes_typed);
                            out.* = .{ .string_from = bytes_expr };
                            owns_bytes_expr = false;
                            return withIntrinsic(makeTypedExprFromId(out, object.type_id), .string_from);
                        }
                    }
                }
            }
            if (object.kind(context) == .string and builtin_method_id != null) {
                if (call.type_args.len != 0) {
                    try context.diagnostic_context.emitToken(path, call.method_token, "method `{s}` does not accept explicit type arguments", .{call.method});
                    return SemaError.SemanticFailed;
                }
                if (builtin_method_id == .string_is_empty) {
                    if (call.args.len != 0) {
                        try context.diagnostic_context.emitToken(path, call.method_token, "string.is_empty expects no arguments", .{});
                        return SemaError.SemanticFailed;
                    }
                    owns_object_expr = false;
                    out.* = .{ .string_is_empty = object.expr };
                    return withIntrinsic(makeTypedExprFromId(out, try canonicalPrimitiveTypeId(context, .bool)), .string_is_empty);
                }
                if (builtin_method_id == .string_bytes) {
                    if (call.args.len != 0) {
                        try context.diagnostic_context.emitToken(path, call.method_token, "string.bytes expects no arguments", .{});
                        return SemaError.SemanticFailed;
                    }
                    owns_object_expr = false;
                    out.* = .{ .string_bytes = object.expr };
                    return withIntrinsic(makeTypedExprFromIdWithProvenance(
                        out,
                        try canonicalSliceTypeId(context, try canonicalIntegerTypeId(context, "u8"), true),
                        try sourceViewProvenance(context, path, program, current_module, globals, locals, call.object),
                    ), .string_bytes);
                }
                if (builtin_method_id == .string_starts_with or
                    builtin_method_id == .string_ends_with or
                    builtin_method_id == .string_contains or
                    builtin_method_id == .string_find or
                    builtin_method_id == .string_rfind)
                {
                    if (call.args.len != 1) {
                        try context.diagnostic_context.emitToken(path, call.method_token, "string.{s} expects one argument", .{call.method});
                        return SemaError.SemanticFailed;
                    }
                    const other = try lowerExpr(context, allocator, path, program, current_module, globals, locals, call.args[0].value, try canonicalPrimitiveTypeId(context, .string));
                    errdefer other.expr.destroy(allocator);
                    try expectType(context, path, firstExprToken(call.args[0].value), try canonicalPrimitiveTypeId(context, .string), other.type_id);
                    owns_object_expr = false;
                    if (builtin_method_id == .string_starts_with) {
                        out.* = .{ .string_starts_with = .{
                            .object = object.expr,
                            .value = other.expr,
                        } };
                    } else if (builtin_method_id == .string_ends_with) {
                        out.* = .{ .string_ends_with = .{
                            .object = object.expr,
                            .value = other.expr,
                        } };
                    } else if (builtin_method_id == .string_find) {
                        out.* = .{ .string_find = .{
                            .object = object.expr,
                            .value = other.expr,
                        } };
                        return withIntrinsic(makeTypedExprFromId(out, try canonicalOptionalTypeId(context, try canonicalIntegerTypeId(context, "usize"))), .string_find);
                    } else if (builtin_method_id == .string_rfind) {
                        out.* = .{ .string_rfind = .{
                            .object = object.expr,
                            .value = other.expr,
                        } };
                        return withIntrinsic(makeTypedExprFromId(out, try canonicalOptionalTypeId(context, try canonicalIntegerTypeId(context, "usize"))), .string_rfind);
                    } else {
                        out.* = .{ .string_contains = .{
                            .object = object.expr,
                            .value = other.expr,
                        } };
                    }
                    return withIntrinsic(
                        makeTypedExprFromId(out, try canonicalPrimitiveTypeId(context, .bool)),
                        builtin_method_id.?,
                    );
                }
                if (builtin_method_id == .string_slice) {
                    if (call.args.len != 2) {
                        try context.diagnostic_context.emitToken(path, call.method_token, "string.slice expects two arguments", .{});
                        return SemaError.SemanticFailed;
                    }
                    const start = try lowerExpr(context, allocator, path, program, current_module, globals, locals, call.args[0].value, try canonicalIntegerTypeId(context, "usize"));
                    errdefer start.expr.destroy(allocator);
                    try expectType(context, path, firstExprToken(call.args[0].value), try canonicalIntegerTypeId(context, "usize"), start.type_id);
                    const end = try lowerExpr(context, allocator, path, program, current_module, globals, locals, call.args[1].value, try canonicalIntegerTypeId(context, "usize"));
                    errdefer end.expr.destroy(allocator);
                    try expectType(context, path, firstExprToken(call.args[1].value), try canonicalIntegerTypeId(context, "usize"), end.type_id);
                    owns_object_expr = false;
                    out.* = .{ .string_slice = .{
                        .object = object.expr,
                        .start = start.expr,
                        .end = end.expr,
                    } };
                    return withIntrinsic(makeTypedExprFromId(out, try canonicalPrimitiveTypeId(context, .string)), .string_slice);
                }
                try context.diagnostic_context.emitToken(path, call.method_token, "string has no method `{s}`", .{call.method});
                return SemaError.SemanticFailed;
            }
            if (object.kind(context) == .sparse_array) {
                if (call.type_args.len != 0) {
                    try context.diagnostic_context.emitToken(path, call.method_token, "method `{s}` does not accept explicit type arguments", .{call.method});
                    return SemaError.SemanticFailed;
                }
                if (builtin_method_id == .sparse_len) {
                    try context.diagnostic_context.emitToken(path, call.method_token, "sparse storage has no method `{s}`", .{call.method});
                    return SemaError.SemanticFailed;
                }
                if (builtin_method_id == .sparse_clear) {
                    try context.diagnostic_context.emitToken(path, call.method_token, "sparse storage has no method `{s}`", .{call.method});
                    return SemaError.SemanticFailed;
                }
                if (builtin_method_id == .sparse_indices) {
                    if (call.args.len != 0) {
                        try context.diagnostic_context.emitToken(path, call.method_token, "sparse.indices expects no arguments", .{});
                        return SemaError.SemanticFailed;
                    }
                    owns_object_expr = false;
                    out.* = .{ .sparse_indices = object.expr };
                    const result_type_id = try canonicalDenseArrayTypeId(context, try canonicalInferredIntegerTypeId(context));
                    return withIntrinsic(
                        makeTypedExprFromIdWithProvenance(out, result_type_id, try propagatedProvenanceForTypeId(context, path, program, current_module, result_type_id, object.provenance.derived())),
                        .sparse_indices,
                    );
                }
                if (builtin_method_id == .sparse_contains_index) {
                    try context.diagnostic_context.emitToken(path, call.method_token, "sparse storage has no method `{s}`", .{call.method});
                    return SemaError.SemanticFailed;
                }
                if (builtin_method_id == .sparse_insert) {
                    if (call.args.len != 2) {
                        try context.diagnostic_context.emitToken(path, call.method_token, "sparse.insert expects two arguments", .{});
                        return SemaError.SemanticFailed;
                    }
                    try expectMutableReceiver(context, path, program, current_module, globals, locals, call.object, object.type_id, "sparse storage");
                    try rejectLiveBorrowContainerMutationConflict(context, path, program, current_module, globals, locals, call.object, "sparse storage", call.method_token, "mutate sparse storage");
                    const index_value = try lowerExpr(context, allocator, path, program, current_module, globals, locals, call.args[0].value, try canonicalInferredIntegerTypeId(context));
                    errdefer index_value.expr.destroy(allocator);
                    try expectType(context, path, firstExprToken(call.args[0].value), try canonicalInferredIntegerTypeId(context), index_value.type_id);
                    const item_type_id = canonicalTypeNode(context, object.type_id).sparse_array;
                    const item_type = item_type_id;
                    const value = try lowerExpr(context, allocator, path, program, current_module, globals, locals, call.args[1].value, item_type_id);
                    errdefer value.expr.destroy(allocator);
                    try expectType(context, path, firstExprToken(call.args[1].value), item_type, value.type_id);
                    try rejectProjectedResourceTransferForTypedValue(context, path, program, firstExprToken(call.args[1].value), value, item_type, "sparse storage insertion");
                    try rejectBorrowedProvenanceMutationEscape(context, path, program, current_module, globals, locals, call.object, value, item_type, firstExprToken(call.args[1].value), "sparse storage mutation");
                    try rejectScopedAllocMutationEscape(context, path, program, current_module, globals, locals, call.object, call.args[1].value, item_type, "sparse storage mutation");
                    try recordMutationProvenance(context, program, current_module, globals, @constCast(locals), call.object, value.provenance);
                    try lowerImplicitHandoff(context, path, program, locals, call.args[1].value, item_type, value.expr);
                    try markCheckedNamedHandoff(context, path, program, @constCast(locals), call.args[1].value, value.expr, item_type);
                    owns_object_expr = false;
                    out.* = .{ .sparse_insert = .{
                        .object = object.expr,
                        .index = index_value.expr,
                        .value = value.expr,
                    } };
                    return withIntrinsic(makeTypedExprFromId(out, try canonicalPrimitiveTypeId(context, .void)), .sparse_insert);
                }
                if (builtin_method_id == .sparse_take) {
                    if (call.args.len != 1) {
                        try context.diagnostic_context.emitToken(path, call.method_token, "sparse.take expects one argument", .{});
                        return SemaError.SemanticFailed;
                    }
                    try expectMutableReceiver(context, path, program, current_module, globals, locals, call.object, object.type_id, "sparse storage");
                    try rejectLiveBorrowContainerMutationConflict(context, path, program, current_module, globals, locals, call.object, "sparse storage", call.method_token, "mutate sparse storage");
                    const index_value = try lowerExpr(context, allocator, path, program, current_module, globals, locals, call.args[0].value, try canonicalInferredIntegerTypeId(context));
                    errdefer index_value.expr.destroy(allocator);
                    try expectType(context, path, firstExprToken(call.args[0].value), try canonicalInferredIntegerTypeId(context), index_value.type_id);
                    const result_type_id = try canonicalOptionalTypeId(context, canonicalTypeNode(context, object.type_id).sparse_array);
                    owns_object_expr = false;
                    out.* = .{ .sparse_take = .{
                        .object = object.expr,
                        .index = index_value.expr,
                    } };
                    return withIntrinsic(
                        makeTypedExprFromIdWithProvenance(out, result_type_id, try propagatedProvenanceForTypeId(context, path, program, current_module, result_type_id, object.provenance.derived())),
                        .sparse_take,
                    );
                }
                try context.diagnostic_context.emitToken(path, call.method_token, "sparse storage has no method `{s}`", .{call.method});
                return SemaError.SemanticFailed;
            }
            if (object.kind(context) == .slice) {
                if (call.type_args.len != 0) {
                    try context.diagnostic_context.emitToken(path, call.method_token, "method `{s}` does not accept explicit type arguments", .{call.method});
                    return SemaError.SemanticFailed;
                }
                if (builtin_method_id == .slice_len) {
                    try context.diagnostic_context.emitToken(path, call.method_token, "slice has no method `{s}`", .{call.method});
                    return SemaError.SemanticFailed;
                }
                try context.diagnostic_context.emitToken(path, call.method_token, "slice has no method `{s}`", .{call.method});
                return SemaError.SemanticFailed;
            }
            if (object.kind(context) == .owned and (builtin_method_id == .owned_ptr or builtin_method_id == .owned_leak)) {
                if (call.type_args.len != 0) {
                    try context.diagnostic_context.emitToken(path, call.method_token, "method `{s}` does not accept explicit type arguments", .{call.method});
                    return SemaError.SemanticFailed;
                }
                if (call.args.len != 0) {
                    try context.diagnostic_context.emitToken(path, call.method_token, "owned.{s} expects no arguments", .{call.method});
                    return SemaError.SemanticFailed;
                }
                if (call.object.* != .name) {
                    try context.diagnostic_context.emitToken(path, firstExprToken(call.object), "owned.{s} requires a local root place", .{call.method});
                    return SemaError.SemanticFailed;
                }
                if (findLocal(locals, call.object.name.text)) |binding| {
                    if (binding.binding_mode == .projected) {
                        try context.diagnostic_context.emitToken(path, call.method_token, "owned.{s} requires an owning local; `{s}` is projected from another owner", .{ call.method, binding.name });
                        return SemaError.SemanticFailed;
                    }
                }
                // The lowered body settles the ownership operation on the receiver's own
                // kind; no parallel syntax walk decides it afterwards.
                try recordLoweredOperationUse(context, call.method, call.method_token, object);
                const name = call.object.name;
                object.expr.destroy(allocator);
                owns_object_expr = false;
                if (builtin_method_id == .owned_leak) {
                    out.* = .{ .leak_owned_local = name.text };
                } else {
                    out.* = .{ .raw_owned_local = name.text };
                }
                return withIntrinsic(
                    makeTypedExprFromId(out, try canonicalRawTypeId(context, canonicalUnwrapOwned(context, object.type_id), false)),
                    builtin_method_id.?,
                );
            }
            if (object.kind(context) == .@"union") {
                if (try protocols.resolveTypeUnionProtocolMethod(SemaContext, context, path, program, current_module, object.type_id, call.method, call.method_token)) |resolved| {
                    if (checked_authority) |authority| {
                        const protocol_id = try registeredDeclId(context, resolved.protocol_decl.module_name, null, resolved.protocol_decl.name, .protocol);
                        const method_id = try registeredDeclId(context, resolved.protocol_decl.module_name, resolved.protocol_decl.name, resolved.method.name, .protocol_method);
                        if (protocol_id != authority.protocol or method_id != authority.method) return error.SemanticFailed;
                    }
                    if (call.type_args.len != 0) {
                        try context.diagnostic_context.emitToken(path, call.method_token, "method `{s}` does not accept explicit type arguments", .{call.method});
                        return SemaError.SemanticFailed;
                    }
                    if (resolved.method.params.len != call.args.len + 1) {
                        try context.diagnostic_context.emitToken(path, call.method_token, "method `{s}` expects {d} args after self, got {d}", .{ call.method, resolved.method.params.len - 1, call.args.len });
                        return SemaError.SemanticFailed;
                    }
                    const self_type = try canonicalNominalTypeId(
                        context,
                        .@"union",
                        try registeredDeclId(context, resolved.union_decl.module_name, null, resolved.union_decl.name, .@"union"),
                        null,
                    );
                    const self_param_type = try parseTypeWithSelf(context, path, program, resolved.protocol_decl.module_name, resolved.method.params[0].type_name, self_type);
                    try expectType(context, path, firstExprToken(call.object), self_param_type, object.type_id);
                    owns_object_expr = false;

                    var args: std.ArrayListUnmanaged(sir.CallArg) = .empty;
                    errdefer {
                        for (args.items) |arg| arg.deinit(allocator);
                        args.deinit(allocator);
                    }
                    try args.append(allocator, .{ .value = object.expr });
                    for (call.args, resolved.method.params[1..]) |arg, param| {
                        const expected = try parseTypeWithSelf(context, path, program, resolved.protocol_decl.module_name, param.type_name, self_type);
                        try appendOwnedLowered(allocator, &args, try lowerCallArg(context, allocator, path, program, current_module, globals, locals, arg, expected, .{
                            .path = moduleSourcePath(program, resolved.protocol_decl.module_name, path),
                            .token = param.type_name.token,
                            .message = "protocol parameter type declared here",
                        }));
                    }
                    const union_callee_decl_id = try registeredOrGeneratedDeclId(context, resolved.union_decl.module_name, resolved.union_decl.name, resolved.method.name, .function);
                    const union_return_type = if (resolved.method.return_type) |type_name|
                        try parseTypeWithSelf(context, path, program, resolved.protocol_decl.module_name, type_name, self_type)
                    else
                        try canonicalPrimitiveTypeId(context, .void);
                    // A union-case witness is already specialized: the union declaration
                    // the method belongs to carries its own concrete payload types, so
                    // this use records no generic substitution.
                    var union_use = try checkedMethodUse(context, call, checked_authority, union_callee_decl_id, union_return_type, null);
                    errdefer if (union_use != null and union_use.?.substitution.len != 0) context.allocator.free(union_use.?.substitution);
                    var owned_args = try args.toOwnedSlice(allocator);
                    errdefer allocator.free(owned_args);
                    out.* = .{ .call = .{
                        .intrinsic_id = intrinsics.resolveDeclaration(resolved.union_decl.module_name, resolved.union_decl.name, resolved.method.name),
                        .decl_id = union_callee_decl_id,
                        .checked_method_use = union_use,
                        .module_name = resolved.union_decl.module_name,
                        .owner = resolved.union_decl.name,
                        .callee = resolved.method.name,
                        .args = owned_args,
                    } };
                    owned_args = &.{};
                    if (union_use == null) try attachCheckedCallUse(context, out, union_return_type, context.function_state.active_source_decl_id, call.method_token.offset);
                    union_use = null;
                    return try makeTypedExprWithProvenance(context, out, union_return_type, object.provenance);
                }
                try context.diagnostic_context.emitToken(path, call.method_token, "union `{s}` has no method `{s}`", .{ canonicalNominalDeclName(context, program, object.type_id).?, call.method });
                return SemaError.SemanticFailed;
            }
            const nominal_receiver_type = normalizedStructReceiverType(context, object.type_id);
            const primitive_receiver_type = if (object.kind(context) == .ref) canonicalRefTarget(context, object.type_id) else object.type_id;
            // Definition-site admission: the receiver is a generic binder, so the
            // binder's declared protocol constraint is the authority and the use
            // lowers to that protocol method's declared contract.
            if (nominal_receiver_type == null and canonicalGenericParameterOf(context, primitive_receiver_type) != null) {
                return try lowerGenericBinderMethodCall(context, allocator, path, program, current_module, globals, locals, out, call, object, checked_authority, primitive_receiver_type, qualified_protocol, &owns_object_expr);
            }
            const primitive_protocol_method = if (nominal_receiver_type == null)
                try protocols.resolveProtocolMethodForType(SemaContext, context, path, program, primitive_receiver_type, call.method, call.method_token, forced_protocol, forced_method)
            else
                null;
            const receiver_type_id = nominal_receiver_type orelse if (primitive_protocol_method != null)
                primitive_receiver_type
            else {
                try context.diagnostic_context.emitToken(path, call.method_token, "type has no method `{s}`", .{call.method});
                return SemaError.SemanticFailed;
            };

            var owned_receiver_name: ?[]const u8 = null;
            defer if (owned_receiver_name) |name| allocator.free(name);
            const struct_name = canonicalNominalDeclName(context, program, receiver_type_id) orelse blk: {
                const name = try formatCanonicalTypeDisplay(context, receiver_type_id);
                owned_receiver_name = name;
                break :blk name;
            };
            const receiver_type = receiver_type_id;
            if (findInstantiatedStructForCanonicalType(context, receiver_type) == null) {
                materializeDefinitionSiteStructInstance(context, path, program, receiver_type);
            }
            var generic_method_params: ?[]const ast.GenericParam = null;
            var generic_method_args: ?[]const semantic_types.GenericArgument = null;
            var owns_generic_method_bindings = false;
            var lowered_method_owner: ?[]const u8 = struct_name;
            var lowered_method_name: []const u8 = call.method;
            var inferred_method_args: std.ArrayListUnmanaged(TypedExpr) = .empty;
            defer {
                for (inferred_method_args.items) |arg| arg.expr.destroy(allocator);
                inferred_method_args.deinit(allocator);
            }
            defer if (owns_generic_method_bindings) {
                context.allocator.free(generic_method_params.?);
                context.allocator.free(generic_method_args.?);
            };
            const method = if (findInstantiatedStructForCanonicalType(context, receiver_type)) |instantiated| blk: {
                const base_decl = findStructInModule(program, instantiated.module_name, instantiated.base_name) orelse {
                    try context.diagnostic_context.emitToken(path, call.method_token, "unknown generic struct base for `{s}`", .{struct_name});
                    return SemaError.SemanticFailed;
                };
                if (if (forced_protocol == null) protocols.findMethodInStruct(base_decl, call.method) else null) |resolved| {
                    if (resolved.type_params.len != 0 and call.type_args.len == 0) {
                        const inference_locals = try allocator.dupe(LocalBinding, locals);
                        defer allocator.free(inference_locals);
                        for (call.args, resolved.params[1..]) |arg, param| {
                            try appendOwnedLowered(allocator, &inferred_method_args, try lowerMethodInferenceArg(context, allocator, path, program, current_module, globals, inference_locals, arg.value, param.type_name));
                        }
                    }
                    const concrete = try instantiateMethodCall(context, allocator, path, program, globals, current_module, struct_name, call.method_token, resolved, base_decl.type_params, instantiated.type_args, call.type_args, if (inferred_method_args.items.len != 0) inferred_method_args.items else null);
                    lowered_method_owner = concrete.owner;
                    lowered_method_name = concrete.name;
                    generic_method_params = concrete.params;
                    generic_method_args = concrete.args;
                    owns_generic_method_bindings = concrete.owns_bindings;
                    break :blk resolved;
                }

                const protocol_method = try protocols.resolveProtocolMethodForType(SemaContext, context, path, program, receiver_type, call.method, call.method_token, forced_protocol, forced_method) orelse {
                    try context.diagnostic_context.emitToken(path, call.method_token, "struct `{s}` has no method `{s}`", .{ struct_name, call.method });
                    return SemaError.SemanticFailed;
                };
                if (call.type_args.len != 0) {
                    try context.diagnostic_context.emitToken(path, call.method_token, "protocol method `{s}` does not accept explicit type arguments", .{call.method});
                    return SemaError.SemanticFailed;
                }
                if (protocol_method.generic_params) |params| {
                    const impl_decl = protocol_method.impl_decl orelse return error.SemanticFailed;
                    const args = protocol_method.generic_args orelse return error.SemanticFailed;
                    const concrete_owner = try concreteGenericImplOwner(context, impl_decl.method_owner, struct_name);
                    const concrete = try instantiateGenericStructMethodForCall(
                        context,
                        allocator,
                        path,
                        program,
                        globals,
                        concrete_owner,
                        call.method_token,
                        protocol_method.decl,
                        params,
                        args,
                    );
                    lowered_method_owner = concrete.owner;
                    lowered_method_name = concrete.name;
                    generic_method_params = params;
                    generic_method_args = args;
                } else {
                    lowered_method_owner = protocol_method.decl.owner;
                }
                break :blk protocol_method.decl;
            } else blk: {
                const inherent_method: ?ast.Function = if (forced_protocol == null)
                    findCanonicalStructMethod(context, program, current_module, receiver_type, call.method)
                else
                    null;
                if (inherent_method) |method_decl| {
                    lowered_method_owner = method_decl.owner;
                    break :blk method_decl;
                }
                const resolved = primitive_protocol_method orelse
                    (try protocols.resolveProtocolMethodForType(SemaContext, context, path, program, receiver_type, call.method, call.method_token, forced_protocol, forced_method) orelse {
                        try context.diagnostic_context.emitToken(path, call.method_token, "struct `{s}` has no method `{s}`", .{ struct_name, call.method });
                        return SemaError.SemanticFailed;
                    });
                lowered_method_owner = resolved.decl.owner;
                break :blk resolved.decl;
            };
            try rejectIsolatedCallToFunction(context, allocator, path, program, current_module, globals, call.method_token, method);
            if (findInstantiatedStructForCanonicalType(context, receiver_type) == null) {
                if (method.type_params.len != 0 and call.type_args.len == 0) {
                    const inference_locals = try allocator.dupe(LocalBinding, locals);
                    defer allocator.free(inference_locals);
                    for (call.args, method.params[1..]) |arg, param| {
                        try appendOwnedLowered(allocator, &inferred_method_args, try lowerMethodInferenceArg(context, allocator, path, program, current_module, globals, inference_locals, arg.value, param.type_name));
                    }
                }
                const concrete = try instantiateMethodCall(context, allocator, path, program, globals, current_module, method.owner orelse struct_name, call.method_token, method, &.{}, &.{}, call.type_args, if (inferred_method_args.items.len != 0) inferred_method_args.items else null);
                lowered_method_owner = concrete.owner;
                lowered_method_name = concrete.name;
                generic_method_params = concrete.params;
                generic_method_args = concrete.args;
                owns_generic_method_bindings = concrete.owns_bindings;
            }

            if (method.params.len == 0) {
                try context.diagnostic_context.emitToken(path, call.method_token, "method `{s}` must declare explicit self parameter", .{call.method});
                return SemaError.SemanticFailed;
            }

            if (method.params.len != call.args.len + 1) {
                try context.diagnostic_context.emitToken(path, call.method_token, "method `{s}` expects {d} args after self, got {d}", .{ call.method, method.params.len - 1, call.args.len });
                return SemaError.SemanticFailed;
            }

            const self_type = if (generic_method_params) |params|
                try parseTypeWithBindings(context, path, program, method.module_name, method.params[0].type_name, null, params, generic_method_args.?)
            else
                try parseTypeWithBindings(context, path, program, method.module_name, method.params[0].type_name, null, &.{}, &.{});
            const hook_id = intrinsics.resolveSyntaxRole(method.syntax_role);
            const return_type = if (method.return_type) |type_name|
                if (generic_method_params) |params|
                    try parseTypeWithBindings(context, path, program, method.module_name, type_name, null, params, generic_method_args.?)
                else
                    try parseTypeWithBindings(context, path, program, method.module_name, type_name, null, &.{}, &.{})
            else
                try canonicalPrimitiveTypeId(context, .void);
            if (concurrency.isOwnedSpawnMethod(method.module_name, method.owner, method.name)) {
                const boundary_args = [_]ast.CallArg{ .{ .value = call.object }, call.args[0], call.args[1] };
                try validateBoundaryArguments(context, allocator, path, program, current_module, globals, "TaskGroup", call.method, call.method_token, &boundary_args, method, generic_method_params, generic_method_args, .{
                    .kind = .concurrent_spawn,
                    .entry_arg_index = 1,
                    .payload_arg_indices = &.{2},
                    .entry_must_be_isolated = false,
                });
                const method_args = generic_method_args orelse return error.SemanticFailed;
                if (method_args.len != 2 or method_args[1] != .type) return error.SemanticFailed;
                const result_payload = method_args[1].type;
                if (!try typeIsThreadTransferable(context, path, program, result_payload)) {
                    const rendered = try formatTypeDisplay(context, result_payload);
                    defer allocator.free(rendered);
                    try context.diagnostic_context.emitToken(path, call.method_token, "concurrency boundary `TaskGroup.spawn` result type `{s}` is not thread-safe to transfer", .{rendered});
                    return error.SemanticFailed;
                }
            }
            try rejectBorrowedMethodStateEscapes(context, path, program, current_module, globals, locals, call, method, self_type, generic_method_params, generic_method_args);
            const lowered_self = if (canonicalTypeKind(context, self_type) == .ref) blk: {
                const requires_mutable_receiver = !canonicalRefIsConst(context, self_type);
                if (requires_mutable_receiver) {
                    try expectMutableReceiver(context, path, program, current_module, globals, locals, call.object, object.type_id, struct_name);
                    if (hook_id != .syntax_index_set) {
                        try rejectLiveBorrowContainerMutationConflict(context, path, program, current_module, globals, locals, call.object, struct_name, call.method_token, "mutate container");
                    }
                }
                if (call.object.* == .name) {
                    const name = call.object.name;
                    if (findLocal(locals, name.text)) |local| {
                        if (local.kind(context) == .ref) {
                            try expectType(context, path, firstExprToken(call.object), self_type, local.type_id);
                            object.expr.destroy(allocator);
                            owns_object_expr = false;
                            const ref_expr = try allocator.create(sir.Expr);
                            ref_expr.* = .{ .ref_alias_local = name.text };
                            break :blk ref_expr;
                        }
                    }
                }
                if (object.kind(context) == .ref) {
                    try expectType(context, path, firstExprToken(call.object), self_type, object.type_id);
                    owns_object_expr = false;
                    break :blk object.expr;
                }
                try expectType(context, path, firstExprToken(call.object), canonicalRefTarget(context, self_type), receiver_type);
                break :blk try lowerBorrowedReceiver(context, allocator, path, program, current_module, globals, locals, call.object, object.expr, object.type_id, &owns_object_expr, !requires_mutable_receiver);
            } else blk: {
                try expectType(context, path, firstExprToken(call.object), self_type, object.type_id);
                try rejectBorrowedResourceTransfer(context, path, program, object.expr, self_type, call.method_token, "method receiver");
                if (std.mem.eql(u8, method.module_name, "std.thread") and
                    ((std.mem.startsWith(u8, struct_name, "Task<") and
                        (std.mem.eql(u8, call.method, "join") or std.mem.eql(u8, call.method, "discard"))) or
                        (std.mem.eql(u8, struct_name, "TaskGroup") and
                            (std.mem.eql(u8, call.method, "finish") or std.mem.eql(u8, call.method, "cancel_and_wait")))))
                {
                    if (call.object.* == .field or call.object.* == .index) {
                        try context.diagnostic_context.emitToken(path, firstExprToken(call.object), "cannot consume concurrency handle through a projected place; keep the handle in a local and pass data or IDs through the aggregate", .{});
                        return error.SemanticFailed;
                    }
                    try rejectProjectedResourceTransferForTypedValue(context, path, program, firstExprToken(call.object), object, self_type, "consuming task method");
                }
                try rejectScopedAllocCallEscape(context, path, program, locals, call.object, self_type, "method call");
                owns_object_expr = false;
                break :blk object.expr;
            };
            var owns_lowered_self = true;
            errdefer if (owns_lowered_self) lowered_self.destroy(allocator);
            if (canonicalTypeKind(context, self_type) == .ref) {
                var self_typed = makeTypedExprFromId(lowered_self, self_type);
                try finalizeAndRecordExprSemantics(context, path, program, current_module, &self_typed);
                try recordLoweredPlaceIdentity(context, allocator, path, program, current_module, globals, locals, call.object, lowered_self);
            }

            var args: std.ArrayListUnmanaged(sir.CallArg) = .empty;
            errdefer {
                for (args.items) |arg| arg.deinit(allocator);
                args.deinit(allocator);
            }
            try args.append(allocator, .{ .value = lowered_self });
            owns_lowered_self = false;

            for (call.args, method.params[1..], 0..) |arg, param, arg_index| {
                const expected = if (generic_method_params) |params|
                    try parseTypeWithBindings(context, path, program, method.module_name, param.type_name, null, params, generic_method_args.?)
                else
                    try parseTypeWithBindings(context, path, program, method.module_name, param.type_name, null, &.{}, &.{});
                const index_syntax_key = call.method_token.tag == .l_bracket and arg_index == 0 and
                    (hook_id == .syntax_index or hook_id == .syntax_index_set) and canonicalTypeKind(context, expected) == .int;
                try appendOwnedLowered(allocator, &args, if (index_syntax_key)
                    try lowerIndexHookIntegerArg(context, allocator, path, program, current_module, globals, locals, arg, expected)
                else
                    try lowerCallArg(context, allocator, path, program, current_module, globals, locals, arg, expected, .{
                        .path = moduleSourcePath(program, method.module_name, path),
                        .token = param.type_name.token,
                        .message = "method parameter type declared here",
                    }));
            }

            const receiver_return_provenance = if (canonicalTypeKind(context, self_type) == .ref)
                receiverRefSourceProvenance(context, program, current_module, globals, locals, call.object)
            else
                object.provenance;
            const receiver_summary_type = if (canonicalTypeKind(context, self_type) == .ref)
                self_type
            else
                receiver_type;
            const return_provenance = try inferredMethodReturnProvenance(context, path, program, current_module, globals, locals, return_type, receiver_return_provenance, receiver_summary_type, call.args, method, generic_method_params, generic_method_args);
            if (context.options.slice_view_normalizations) |normalizations| {
                if (method.is_slice_view and call.args.len == 0 and call.type_args.len == 0 and context.function_state.current_generic_params.len == 0) {
                    if (try selectSliceViewMethod(context, path, program, current_module, object.type_id, sliceReceiverWritable(context, program, current_module, globals, locals, call.object, object.type_id), call.method_token)) |selected| {
                        if (std.mem.eql(u8, selected.module_name, method.module_name) and optionalEql(selected.owner, method.owner) and std.mem.eql(u8, selected.name, method.name)) {
                            try normalizations.append(context.allocator, .{ .module_name = current_module, .method_offset = call.method_token.offset });
                        }
                    }
                }
            }
            const lowered_callee_decl_id = maybeRegisteredDeclId(context, method.module_name, lowered_method_owner, lowered_method_name, .function);
            if (call.object.* == .name and std.mem.eql(u8, method.module_name, "std.thread")) {
                const consumes_task = std.mem.startsWith(u8, struct_name, "Task<") and
                    (std.mem.eql(u8, call.method, "join") or std.mem.eql(u8, call.method, "discard"));
                const settles_group = std.mem.eql(u8, struct_name, "TaskGroup") and
                    (std.mem.eql(u8, call.method, "finish") or std.mem.eql(u8, call.method, "cancel_and_wait"));
                if (consumes_task or settles_group)
                    try markLocalHandedOff(context, path, @constCast(locals), call.object.name);
            }
            // The type arguments the callee's own signature received are the
            // substitution this use settled, so the record names the concrete signature
            // the body actually reached.
            var lowered_use = try checkedMethodUse(context, call, checked_authority, lowered_callee_decl_id, return_type, generic_method_args);
            errdefer if (lowered_use != null and lowered_use.?.substitution.len != 0) context.allocator.free(lowered_use.?.substitution);
            var owned_args = try args.toOwnedSlice(allocator);
            errdefer {
                for (owned_args) |arg| arg.deinit(allocator);
                allocator.free(owned_args);
            }
            out.* = .{ .call = .{
                .intrinsic_id = intrinsics.resolveDeclaration(method.module_name, lowered_method_owner, lowered_method_name) orelse hook_id,
                .decl_id = lowered_callee_decl_id,
                .checked_method_use = lowered_use,
                .module_name = method.module_name,
                .owner = lowered_method_owner,
                .callee = lowered_method_name,
                .args = owned_args,
            } };
            errdefer out.* = .none;
            if (lowered_use == null) try attachCheckedCallUse(context, out, return_type, context.function_state.active_source_decl_id, call.method_token.offset);
            owned_args = &.{};
            lowered_use = null;
            return try makeTypedExprWithProvenance(
                context,
                out,
                return_type,
                return_provenance,
            );
        }

        pub fn lowerBuiltinInsertMethodCall(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            call: ast.MethodCall,
            object: TypedExpr,
            method_builtin: TypeBuiltinInsertMethod,
        ) SemaError!TypedExpr {
            try expectOneArgMethod(context, path, call, method_builtin.owner_name, method_builtin.method_name);
            try prepareMutableContainerMethod(context, path, program, current_module, globals, locals, call.object, object.type_id, method_builtin.receiver_name, call.method_token, method_builtin.mutation_action);
            const item_type = method_builtin.item_type_id;
            var value = try lowerExpr(context, allocator, path, program, current_module, globals, locals, call.args[0].value, method_builtin.item_type_id);
            errdefer value.expr.destroy(allocator);
            try expectType(context, path, firstExprToken(call.args[0].value), item_type, value.type_id);
            if (value.type_id != item_type and canonicalTypeKind(context, value.type_id) == .int and
                canonicalTypeKind(context, item_type) == .int)
            {
                const converted = try allocator.create(sir.Expr);
                converted.* = .{ .cast = .{
                    .subject = value.expr,
                    .target_type_id = item_type,
                    .union_case_name = null,
                    .fallible = false,
                    .reinterpret = false,
                } };
                value = makeTypedExprFromId(converted, item_type);
                try finalizeAndRecordExprSemantics(context, path, program, current_module, &value);
            }
            try rejectBorrowedProvenanceMutationEscape(context, path, program, current_module, globals, locals, call.object, value, item_type, firstExprToken(call.args[0].value), method_builtin.mutation_action);
            try rejectScopedAllocMutationEscape(context, path, program, current_module, globals, locals, call.object, call.args[0].value, item_type, method_builtin.mutation_action);
            try recordMutationProvenance(context, program, current_module, globals, @constCast(locals), call.object, value.provenance);
            try lowerImplicitHandoff(context, path, program, locals, call.args[0].value, item_type, value.expr);
            try markCheckedNamedHandoff(context, path, program, @constCast(locals), call.args[0].value, value.expr, item_type);
            out.* = .{ .sequence_push = .{
                .object = object.expr,
                .value = value.expr,
            } };
            return withIntrinsic(makeTypedExprFromId(out, try canonicalPrimitiveTypeId(context, .void)), .sequence_push);
        }

        pub fn lowerBuiltinReserveMethodCall(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            call: ast.MethodCall,
            object: TypedExpr,
            method_builtin: TypeBuiltinReserveMethod,
        ) SemaError!TypedExpr {
            try expectOneArgMethod(context, path, call, method_builtin.owner_name, method_builtin.method_name);
            try prepareMutableContainerMethod(context, path, program, current_module, globals, locals, call.object, object.type_id, method_builtin.receiver_name, call.method_token, method_builtin.mutation_action);
            const capacity = try lowerExpr(context, allocator, path, program, current_module, globals, locals, call.args[0].value, try canonicalInferredIntegerTypeId(context));
            errdefer capacity.expr.destroy(allocator);
            try expectType(context, path, firstExprToken(call.args[0].value), try canonicalInferredIntegerTypeId(context), capacity.type_id);
            out.* = .{ .sequence_reserve = .{
                .object = object.expr,
                .capacity = capacity.expr,
            } };
            return withIntrinsic(makeTypedExprFromId(out, try canonicalPrimitiveTypeId(context, .void)), .sequence_reserve);
        }

        pub fn inferGenericArgsFromBoundaryPayload(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            function: ast.Function,
            call_args: []const ast.CallArg,
            contract: concurrency.Contract,
        ) SemaError![]semantic_types.GenericArgument {
            const allocator = context.allocator;
            const inferred = try allocator.alloc(?semantic_types.GenericArgument, function.type_params.len);
            defer allocator.free(inferred);
            @memset(inferred, null);

            for (contract.payload_arg_indices) |arg_index| {
                if (arg_index >= function.params.len or arg_index >= call_args.len) {
                    try context.diagnostic_context.emitToken(path, function.name_token, "concurrency boundary `{s}` has invalid generic payload contract", .{function.name});
                    return SemaError.SemanticFailed;
                }
                const param = function.params[arg_index];
                const arg = call_args[arg_index];
                const typed = try lowerExpr(context, allocator, path, program, current_module, globals, locals, arg.value, null);
                defer typed.expr.destroy(allocator);
                try unifyGenericBinding(context, path, program, function.module_name, param.type_name, typed.type_id, function.type_params, inferred);
            }

            var result = try allocator.alloc(semantic_types.GenericArgument, function.type_params.len);
            errdefer allocator.free(result);
            for (function.type_params, inferred, 0..) |param, maybe_ty, i| {
                const ty = maybe_ty orelse {
                    try context.diagnostic_context.emitToken(path, param.name_token, "could not infer generic parameter `{s}` from concurrency boundary payload", .{param.name});
                    return SemaError.SemanticFailed;
                };
                if (!param.is_const_value) {
                    try protocols.expectGenericParamProtocolConformance(SemaContext, typeIsOwnedForProtocol, context, path, program, function.module_name, param, param.name_token, ty.type);
                }
                result[i] = ty;
            }
            return result;
        }

        pub fn lowerSliceRange(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            slice: ast.SliceRange,
        ) SemaError!TypedExpr {
            var object = try lowerExpr(context, allocator, path, program, current_module, globals, locals, slice.object, null);
            var owns_object = true;
            errdefer if (owns_object) object.expr.destroy(allocator);
            // A binder-typed receiver has no concrete container kind yet, so the slice
            // form is deferred and re-checked by each specialization.
            if (type_resolution.typeSliceViewItemType(typeConstructionContext(context), object.type_id) == null and type_resolution.containsDefinitionSiteBinder(canonicalTypeInterner(context), object.type_id)) {
                const payload = try loweredProjectionShape(context, object.generic_shape, null, .slice);
                return try deferredDefinitionSiteValue(context, allocator, path, program, current_module, &object, out, try definitionSiteDeferredType(context, "slice"), payload);
            }
            const uses_view_method = type_resolution.typeSliceViewItemType(typeConstructionContext(context), object.type_id) == null;
            if (uses_view_method) {
                const method = (try selectSliceViewMethod(context, path, program, current_module, object.type_id, sliceReceiverWritable(context, program, current_module, globals, locals, slice.object, object.type_id), slice.token)) orelse {
                    try context.diagnostic_context.emitToken(path, slice.token, "slice expression requires an array, dense storage, slice, or string; library targets require an accessible `syntax.slice_view` method for this receiver access", .{});
                    return SemaError.SemanticFailed;
                };
                const call_expr = try allocator.create(sir.Expr);
                var owns_call_allocation = true;
                errdefer if (owns_call_allocation) allocator.destroy(call_expr);
                owns_object = false;
                object = try lowerMethodCallWithReceiver(context, allocator, path, program, current_module, globals, locals, call_expr, .{
                    .object = slice.object,
                    .method = method.name,
                    .method_token = slice.token,
                    .type_args = &.{},
                    .args = &.{},
                }, null, object);
                owns_call_allocation = false;
                owns_object = true;
                try finalizeAndRecordExprSemantics(context, path, program, current_module, &object);
            }
            const item_type_id = type_resolution.typeSliceViewItemType(typeConstructionContext(context), object.type_id) orelse {
                try context.diagnostic_context.emitToken(path, slice.token, "slice expression requires an array, dense storage, slice, or string", .{});
                return SemaError.SemanticFailed;
            };
            const start = if (slice.start) |start_expr| blk: {
                const lowered = try lowerExpr(context, allocator, path, program, current_module, globals, locals, start_expr, try canonicalInferredIntegerTypeId(context));
                errdefer lowered.expr.destroy(allocator);
                try expectType(context, path, firstExprToken(start_expr), try canonicalInferredIntegerTypeId(context), lowered.type_id);
                break :blk lowered.expr;
            } else null;
            errdefer if (start) |expr| expr.destroy(allocator);
            const end = if (slice.end) |end_expr| blk: {
                const lowered = try lowerExpr(context, allocator, path, program, current_module, globals, locals, end_expr, try canonicalInferredIntegerTypeId(context));
                errdefer lowered.expr.destroy(allocator);
                try expectType(context, path, firstExprToken(end_expr), try canonicalInferredIntegerTypeId(context), lowered.type_id);
                break :blk lowered.expr;
            } else null;
            errdefer if (end) |expr| expr.destroy(allocator);
            const view_provenance = if (uses_view_method or object.provenance.hasBorrow())
                object.provenance.derived()
            else
                try sourceViewProvenance(context, path, program, current_module, globals, locals, slice.object);
            out.* = .{ .slice_range = .{
                .object = object.expr,
                .start = start,
                .end = end,
            } };
            const source_place_read_only = if (resolvePlace(context, program, current_module, globals, locals, slice.object)) |place|
                place.access == .read_only
            else switch (slice.object.*) {
                // Unresolved place-shaped syntax must not silently acquire writable
                // access. Other forms are explicit temporary values whose view lasts
                // only according to the normal provenance/escape checks.
                .name, .field, .index, .deref, .address_of => true,
                else => false,
            };
            return makeTypedExprFromIdWithProvenance(
                out,
                try canonicalSliceTypeId(context, item_type_id, canonicalSliceIsConst(context, object.type_id) or
                    (canonicalTypeNode(context, object.type_id).* != .slice and
                        source_place_read_only)),
                view_provenance,
            );
        }

        pub fn lowerIndex(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            index: ast.Index,
        ) SemaError!TypedExpr {
            var object = try lowerExpr(context, allocator, path, program, current_module, globals, locals, index.object, null);
            var owns_object_expr = true;
            errdefer if (owns_object_expr) object.expr.destroy(allocator);
            try recordLoweredOperationUse(context, "index", index.token, object);
            const element_shape = try loweredProjectionShape(context, object.generic_shape, try loweredIndexElementType(context, path, program, current_module, object.type_id), .index);
            const index_role = (try type_resolution.typeIndexAccessRole(typeConstructionContext(context), object.type_id)) orelse {
                if (isDefinitionSiteBinder(context, object.type_id)) {
                    // The container layer the body cannot settle still names the element
                    // origins it joined, so the deferred read keeps them.
                    var deferred = try deferConcreteKindForm(context, allocator, path, program, current_module, &object, out);
                    deferred.generic_shape = element_shape;
                    return deferred;
                }
                if (selectSyntaxMethod(context, program, current_module, object.type_id, .index)) |method| {
                    if (try indexHookReturnTypeForType(context, path, program, current_module, object.type_id)) |return_type| {
                        if (canonicalTypeKind(context, return_type) != .ref and try typeIsOwnedValue(context, path, program, return_type)) {
                            const return_type_name = try formatTypeDisplay(context, return_type);
                            defer allocator.free(return_type_name);
                            try context.diagnostic_context.emitTokenWith(path, index.token, .{
                                .code = .ownership,
                                .notes = &.{"the `syntax.index` method returns its item by value"},
                                .help = "use an API that returns an alias, an explicit copy, or a detachable value",
                            }, "cannot read resource item type `{s}` through a by-value index hook", .{return_type_name});
                            return SemaError.SemanticFailed;
                        }
                    }
                    var hook_args = [_]ast.CallArg{.{ .value = index.index }};
                    const hook_call = ast.MethodCall{
                        .object = index.object,
                        .method = method.name,
                        .method_token = index.token,
                        .type_args = &.{},
                        .args = &hook_args,
                    };
                    const hook_expr = try allocator.create(sir.Expr);
                    var owns_hook_allocation = true;
                    var hook_initialized = false;
                    errdefer if (owns_hook_allocation) {
                        if (hook_initialized) hook_expr.destroy(allocator) else allocator.destroy(hook_expr);
                    };
                    var lowered = try lowerMethodCallInternal(context, allocator, path, program, current_module, globals, locals, hook_expr, hook_call, null);
                    hook_initialized = true;
                    errdefer out.* = .none;
                    object.expr.destroy(allocator);
                    owns_object_expr = false;
                    if (lowered.kind(context) == .ref) {
                        try finalizeAndRecordExprSemantics(context, path, program, current_module, &lowered);
                        const ref_expr = lowered.expr;
                        const ref_target_id = canonicalRefTarget(context, lowered.type_id);
                        out.* = .{ .ref_load = ref_expr };
                        return makeTypedExprFromIdWithProvenanceAndValueSemantics(
                            out,
                            ref_target_id,
                            lowered.provenance,
                            projectedReadValueSemantics(
                                try typeHasStorageLifetime(context, path, program, ref_target_id),
                                try typeMayCarryBorrowedProvenance(context, path, program, current_module, ref_target_id),
                            ),
                        );
                    }
                    out.* = hook_expr.*;
                    allocator.destroy(hook_expr);
                    owns_hook_allocation = false;
                    errdefer {
                        out.deinit(allocator);
                        out.* = .none;
                    }
                    lowered.expr = out;
                    try finalizeAndRecordExprSemantics(context, path, program, current_module, &lowered);
                    return lowered;
                }
                try context.diagnostic_context.emitToken(path, index.token, "indexing requires an indexable foundation type or an accessible `syntax.index` method", .{});
                return SemaError.SemanticFailed;
            };
            const index_type = index_role.key_type_id;
            const index_value = try lowerExpr(context, allocator, path, program, current_module, globals, locals, index.index, index_type);
            errdefer index_value.expr.destroy(allocator);
            try expectType(context, path, firstExprToken(index.index), index_type, index_value.type_id);
            if (object.kind(context) == .sparse_array) {
                // Sparse lookup materializes an optional result; it does not expose an
                // addressable element place. Keep its value semantics independent from
                // the storage lifetime of the optional payload.
                const result_is_owned_value = try typeIsOwnedValue(context, path, program, index_role.value_type_id);
                const result_may_carry_borrowed = try typeMayCarryBorrowedProvenance(context, path, program, current_module, index_role.value_type_id);
                out.* = if (projectedReadValueSemantics(result_is_owned_value, result_may_carry_borrowed).category == .borrowed_projection)
                    .{ .borrowed_index = .{
                        .object = object.expr,
                        .index = index_value.expr,
                    } }
                else
                    .{ .index = .{
                        .object = object.expr,
                        .index = index_value.expr,
                    } };
                return try makeTypedExprWithProvenanceAndValueSemantics(
                    context,
                    out,
                    index_role.value_type_id,
                    Provenance.combine(object.provenance.derived(), index_value.provenance),
                    projectedReadValueSemantics(result_is_owned_value, result_may_carry_borrowed),
                );
            }
            const result_has_storage_lifetime = try typeHasStorageLifetime(context, path, program, index_role.value_type_id);
            const result_may_carry_borrowed = try typeMayCarryBorrowedProvenance(context, path, program, current_module, index_role.value_type_id);
            out.* = if (projectedReadValueSemantics(result_has_storage_lifetime, result_may_carry_borrowed).category == .borrowed_projection)
                .{ .borrowed_index = .{
                    .object = object.expr,
                    .index = index_value.expr,
                } }
            else
                .{ .index = .{
                    .object = object.expr,
                    .index = index_value.expr,
                } };
            var result = try makeTypedExprWithProvenanceAndValueSemantics(
                context,
                out,
                index_role.value_type_id,
                Provenance.combine(object.provenance.derived(), index_value.provenance),
                projectedReadValueSemantics(result_has_storage_lifetime, result_may_carry_borrowed),
            );
            result.generic_shape = element_shape;
            return result;
        }

        pub fn lowerIndexHookIntegerArg(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            arg: ast.CallArg,
            expected: semantic_types.TypeId,
        ) SemaError!sir.CallArg {
            const expr = arg.value;
            const lowered = try lowerExpr(context, allocator, path, program, current_module, globals, locals, expr, null);
            errdefer lowered.expr.destroy(allocator);
            if (canonicalTypeKind(context, lowered.type_id) != .int) {
                try expectType(context, path, firstExprToken(expr), expected, lowered.type_id);
                return error.SemanticFailed;
            }
            if (context.options.index_cast_normalizations) |normalizations| {
                if (expr.* == .cast and lowered.expr.* == .cast) {
                    const cast = expr.cast;
                    if (!cast.fallible and !cast.reinterpret and lowered.type_id == expected and
                        cast.target.args.len == 0)
                    {
                        if (semanticExprMetadata(context, lowered.expr.cast.subject)) |subject| {
                            if (canonicalTypeKind(context, subject.type_id) == .int) {
                                try normalizations.append(context.allocator, .{
                                    .module_name = current_module,
                                    .cast_offset = cast.token.offset,
                                    .target_end_offset = cast.target.token.end_offset,
                                });
                            }
                        }
                    }
                }
            }
            if (expected == lowered.type_id) return .{ .value = lowered.expr };
            const converted = try allocator.create(sir.Expr);
            errdefer allocator.destroy(converted);
            converted.* = .{ .cast = .{
                .subject = lowered.expr,
                .target_type_id = expected,
                .union_case_name = null,
                .fallible = false,
                .reinterpret = false,
            } };
            var typed = makeTypedExprFromId(converted, expected);
            try finalizeAndRecordExprSemantics(context, path, program, current_module, &typed);
            return .{ .value = converted };
        }

        pub fn lowerCallArg(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            arg: ast.CallArg,
            expected: semantic_types.TypeId,
            expectation_origin: ?TypeExpectationOrigin,
        ) SemaError!sir.CallArg {
            const saved_expectation_origin = context.function_state.expected_type_origin;
            context.function_state.expected_type_origin = expectation_origin;
            defer context.function_state.expected_type_origin = saved_expectation_origin;

            if (canonicalTypeKind(context, expected) == .ref) switch (arg) {
                .value => |expr| {
                    if (expr.* == .name) {
                        const name = expr.name;
                        if (findLocal(locals, name.text)) |local| {
                            if (local.kind(context) == .ref) {
                                try expectTypeFrom(context, path, firstExprToken(expr), expected, local.type_id, expectation_origin);
                                const ref_expr = try allocator.create(sir.Expr);
                                ref_expr.* = .{ .ref_alias_local = name.text };
                                errdefer ref_expr.destroy(allocator);
                                var ref_typed = makeTypedExprFromId(ref_expr, expected);
                                try finalizeAndRecordExprSemantics(context, path, program, current_module, &ref_typed);
                                try recordLoweredPlaceIdentity(context, allocator, path, program, current_module, globals, locals, expr, ref_expr);
                                return .{ .value = ref_expr };
                            }
                        }
                    }
                    const lowered = try lowerExpr(context, allocator, path, program, current_module, globals, locals, expr, null);
                    var owns_expr = true;
                    errdefer if (owns_expr) lowered.expr.destroy(allocator);
                    if (lowered.kind(context) == .ref) {
                        try expectTypeFrom(context, path, firstExprToken(expr), expected, lowered.type_id, expectation_origin);
                        return .{ .value = lowered.expr };
                    }
                    if (lowered.kind(context) == .owned) {
                        try expectTypeFrom(context, path, firstExprToken(expr), canonicalRefTarget(context, expected), canonicalOwnedTarget(context, lowered.type_id), expectation_origin);
                        const borrowed = try lowerBorrowedReceiver(context, allocator, path, program, current_module, globals, locals, expr, lowered.expr, lowered.type_id, &owns_expr, false);
                        errdefer borrowed.destroy(allocator);
                        var borrowed_typed = makeTypedExprFromId(borrowed, expected);
                        try finalizeAndRecordExprSemantics(context, path, program, current_module, &borrowed_typed);
                        try recordLoweredPlaceIdentity(context, allocator, path, program, current_module, globals, locals, expr, borrowed);
                        return .{ .value = borrowed };
                    }
                    lowered.expr.destroy(allocator);
                    owns_expr = false;
                },
            };
            return switch (arg) {
                .value => |expr| blk: {
                    const lowered = try lowerExprInContext(context, allocator, path, program, current_module, globals, locals, expr, expected);
                    errdefer lowered.expr.destroy(allocator);
                    try expectTypeFrom(context, path, firstExprToken(expr), expected, lowered.type_id, expectation_origin);
                    try rejectScopedAllocCallEscape(context, path, program, locals, expr, expected, "function call");
                    try rejectProjectedResourceTransferForTypedValue(context, path, program, firstExprToken(expr), lowered, expected, "function call");
                    try rejectBorrowedResourceTransfer(context, path, program, lowered.expr, expected, firstExprToken(expr), "function argument");
                    try lowerImplicitHandoff(context, path, program, locals, expr, expected, lowered.expr);
                    try markCheckedNamedHandoff(context, path, program, @constCast(locals), expr, lowered.expr, expected);
                    break :blk .{ .value = lowered.expr };
                },
            };
        }

        pub fn lowerExprInContext(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            expr: *ast.Expr,
            expected_type_id: ?semantic_types.TypeId,
        ) SemaError!TypedExpr {
            if (expected_type_id) |target_type_id| {
                const target_node = canonicalTypeNode(context, target_type_id);
                if (target_node.* == .primitive and target_node.primitive == .c_str and expr.* == .string) {
                    const literal = expr.string;
                    if (std.mem.indexOfScalar(u8, literal.text, 0) != null) {
                        try context.diagnostic_context.emitToken(path, literal.token, "`c_str` literals cannot contain an embedded NUL byte", .{});
                        return SemaError.SemanticFailed;
                    }

                    const subject = try lowerExpr(context, allocator, path, program, current_module, globals, locals, expr, null);
                    errdefer subject.expr.destroy(allocator);
                    const wrapper = try allocator.create(sir.Expr);
                    errdefer allocator.destroy(wrapper);
                    wrapper.* = .{ .cast = .{
                        .subject = subject.expr,
                        .target_type_id = target_type_id,
                        .union_case_name = null,
                        .fallible = false,
                        .reinterpret = false,
                    } };
                    var adapted = makeTypedExprFromIdWithProvenance(wrapper, target_type_id, .staticValue());
                    try finalizeAndRecordExprSemantics(context, path, program, current_module, &adapted);
                    return adapted;
                }
                if (target_node.* == .optional and expr.* == .union_case) {
                    return lowerExprInContext(context, allocator, path, program, current_module, globals, locals, expr, target_node.optional);
                }
                if (canonicalTypeKind(context, target_type_id) == .@"enum" and expr.* == .union_case) {
                    const case = expr.union_case;
                    if (case.value != null) {
                        try context.diagnostic_context.emitToken(path, case.token, "enum case `.{s}` does not take a payload", .{case.case_name});
                        return SemaError.SemanticFailed;
                    }
                    const enum_out = try allocator.create(sir.Expr);
                    errdefer allocator.destroy(enum_out);
                    var lowered_enum = try lowerEnumCaseForType(context, path, program, enum_out, target_type_id, case.case_name, case.token);
                    try finalizeAndRecordExprSemantics(context, path, program, current_module, &lowered_enum);
                    return lowered_enum;
                }
                if (canonicalTypeKind(context, target_type_id) == .ref) switch (expr.*) {
                    .name => |name| {
                        if (findLocal(locals, name.text)) |local| {
                            if (local.kind(context) == .ref) {
                                try expectTypeFrom(context, path, firstExprToken(expr), target_type_id, local.type_id, context.function_state.expected_type_origin);
                                const ref_expr = try allocator.create(sir.Expr);
                                ref_expr.* = .{ .ref_alias_local = name.text };
                                errdefer ref_expr.destroy(allocator);
                                var lowered_ref = makeTypedExprFromIdWithProvenance(ref_expr, target_type_id, local.provenance);
                                try finalizeAndRecordExprSemantics(context, path, program, current_module, &lowered_ref);
                                try recordLoweredPlaceIdentity(context, allocator, path, program, current_module, globals, locals, expr, ref_expr);
                                return lowered_ref;
                            }
                        }
                    },
                    else => {},
                };
            }

            var lowered = try lowerExpr(context, allocator, path, program, current_module, globals, locals, expr, expected_type_id);
            var owns_lowered = true;
            errdefer if (owns_lowered) lowered.expr.destroy(allocator);

            // A terminal expression never produces a value to compare with the expected type.
            if (sir.exprDefinitelyDiverges(lowered.expr)) return lowered;
            const target_id = expected_type_id orelse return lowered;
            if (type_resolution.compatible(canonicalTypeInterner(context), target_id, lowered.type_id)) {
                if (lowered.expr.* == .local and
                    canonicalTypeNode(context, lowered.type_id).* == .inferred_integer and
                    canonicalTypeNode(context, target_id).* == .integer)
                {
                    const wrapper = try allocator.create(sir.Expr);
                    wrapper.* = .{ .cast = .{
                        .subject = lowered.expr,
                        .target_type_id = target_id,
                        .union_case_name = null,
                        .fallible = false,
                        .reinterpret = false,
                    } };
                    owns_lowered = false;
                    errdefer wrapper.destroy(allocator);
                    var wrapped = makeTypedExprFromIdWithProvenance(wrapper, target_id, lowered.provenance);
                    try finalizeAndRecordExprSemantics(context, path, program, current_module, &wrapped);
                    return wrapped;
                }
                return lowered;
            }
            if (try typeUnionVariantCaseName(context, allocator, path, program, target_id, lowered.type_id, firstExprToken(expr))) |case_name| {
                const inline_members = switch (canonicalTypeNode(context, target_id).*) {
                    .error_union => |members| members,
                    else => null,
                };
                const union_name = if (inline_members != null) "__inline_error_union" else canonicalNominalDeclName(context, program, target_id) orelse return error.SemanticFailed;
                const inline_ordinal: ?u32 = if (inline_members) |members| for (members, 0..) |member, index| {
                    if (member == lowered.type_id) break @intCast(index);
                } else null else null;
                const wrapper = try allocator.create(sir.Expr);
                wrapper.* = .{ .union_case = .{
                    .decl_id = canonicalNominalDeclId(context, target_id),
                    .inline_union_type_id = if (inline_members != null) target_id else null,
                    .inline_union_ordinal = inline_ordinal,
                    .union_name = union_name,
                    .case_name = case_name,
                    .value = lowered.expr,
                } };
                owns_lowered = false;
                errdefer wrapper.destroy(allocator);
                var wrapped = makeTypedExprFromIdWithProvenance(wrapper, target_id, lowered.provenance);
                try finalizeAndRecordExprSemantics(context, path, program, current_module, &wrapped);
                return wrapped;
            }

            try expectTypeFrom(context, path, firstExprToken(expr), target_id, lowered.type_id, context.function_state.expected_type_origin);
            return lowered;
        }

        pub fn lowerBorrowedReceiver(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            source_expr: *ast.Expr,
            lowered_expr: *sir.Expr,
            lowered_ty: semantic_types.TypeId,
            owns_expr: *bool,
            allow_const_root: bool,
        ) SemaError!*sir.Expr {
            if (source_expr.* == .name) {
                const name = source_expr.name;
                if (findLocal(locals, name.text) != null) {
                    const place = resolvePlace(context, program, current_module, globals, locals, source_expr) orelse
                        return SemaError.SemanticFailed;
                    if (!allow_const_root and !place.access.allowsMutation()) {
                        try context.diagnostic_context.emitToken(path, name.token, "cannot create alias to const receiver `{s}`", .{name.text});
                        return SemaError.SemanticFailed;
                    }
                    lowered_expr.destroy(allocator);
                    owns_expr.* = false;
                    const ref_expr = try allocator.create(sir.Expr);
                    if (canonicalTypeKind(context, lowered_ty) == .owned) {
                        ref_expr.* = .{ .ref_owned_local = name.text };
                    } else {
                        ref_expr.* = .{ .ref_alias_local = name.text };
                    }
                    return ref_expr;
                }
                if (findGlobal(context, program, globals, current_module, name.text)) |global| {
                    const place = resolvePlace(context, program, current_module, globals, locals, source_expr) orelse
                        return SemaError.SemanticFailed;
                    if (!allow_const_root and !place.access.allowsMutation()) {
                        try context.diagnostic_context.emitToken(path, name.token, "cannot create alias to const receiver `{s}`", .{name.text});
                        return SemaError.SemanticFailed;
                    }
                    lowered_expr.destroy(allocator);
                    owns_expr.* = false;
                    const ref_expr = try allocator.create(sir.Expr);
                    ref_expr.* = .{ .ref_global = .{
                        .decl_id = global.id,
                        .module_name = global.module_name,
                        .owner = global.owner,
                        .name = global.name,
                    } };
                    return ref_expr;
                }
                try context.diagnostic_context.emitToken(path, name.token, "unknown local `{s}`", .{name.text});
                return SemaError.SemanticFailed;
            }

            var reversed_steps: std.ArrayListUnmanaged(TakeAstStep) = .empty;
            defer reversed_steps.deinit(allocator);
            const root_name = try collectPlaceRootAndSteps(context, allocator, path, source_expr, &reversed_steps, "borrowed receiver requires an addressable place");
            const place = resolvePlace(context, program, current_module, globals, locals, source_expr) orelse
                return SemaError.SemanticFailed;
            const local = findLocal(locals, root_name.text) orelse {
                const global = findGlobal(context, program, globals, current_module, root_name.text) orelse {
                    try context.diagnostic_context.emitToken(path, root_name.token, "unknown local `{s}`", .{root_name.text});
                    return SemaError.SemanticFailed;
                };
                if (!allow_const_root and !place.access.allowsMutation()) {
                    try context.diagnostic_context.emitToken(path, root_name.token, "cannot create alias to const receiver `{s}`", .{root_name.text});
                    return SemaError.SemanticFailed;
                }
                lowered_expr.destroy(allocator);
                owns_expr.* = false;
                return try lowerBorrowedGlobalFieldReceiver(context, allocator, path, program, current_module, root_name, global, reversed_steps.items);
            };
            if (!allow_const_root and !place.access.allowsMutation()) {
                try context.diagnostic_context.emitToken(path, root_name.token, "cannot create alias to const receiver `{s}`", .{root_name.text});
                return SemaError.SemanticFailed;
            }
            lowered_expr.destroy(allocator);
            owns_expr.* = false;

            if (source_expr.* == .index) {
                const hook_expr = try allocator.create(sir.Expr);
                errdefer allocator.destroy(hook_expr);
                if (try lowerIndexHookAlias(context, allocator, path, program, current_module, globals, locals, hook_expr, source_expr.index)) |hook_alias| {
                    return hook_alias.expr;
                }
                allocator.destroy(hook_expr);
            }
            if (source_expr.* == .field) {
                const hook_expr = try allocator.create(sir.Expr);
                errdefer allocator.destroy(hook_expr);
                if (try lowerHookIndexedFieldAlias(context, allocator, path, program, current_module, globals, locals, hook_expr, source_expr)) |hook_alias| {
                    return hook_alias.expr;
                }
                allocator.destroy(hook_expr);
            }

            if (reversed_steps.items.len == 0) {
                const ref_expr = try allocator.create(sir.Expr);
                if (canonicalTypeKind(context, lowered_ty) == .owned) {
                    ref_expr.* = .{ .ref_owned_local = root_name.text };
                } else {
                    ref_expr.* = .{ .ref_alias_local = root_name.text };
                }
                return ref_expr;
            }
            const step = reversed_steps.items[0];
            const ref_expr = try allocator.create(sir.Expr);
            errdefer allocator.destroy(ref_expr);
            if (reversed_steps.items.len != 1) {
                var sir_steps: std.ArrayListUnmanaged(sir.TakePathStep) = .empty;
                errdefer {
                    for (sir_steps.items) |sir_step| switch (sir_step) {
                        .field => {},
                        .index => |index_expr| index_expr.destroy(allocator),
                    };
                    sir_steps.deinit(allocator);
                }
                var current_type = try borrowedRootTypeForPath(context, local, source_expr);
                var i: usize = reversed_steps.items.len;
                while (i > 0) {
                    i -= 1;
                    const ast_step = reversed_steps.items[i];
                    try sir_steps.append(allocator, switch (ast_step) {
                        .field => |field| blk: {
                            const resolved = try typeStructField(context, path, program, current_module, current_type, field.field, field.field_token);
                            if (resolved.decl.layout == .@"packed") {
                                try context.diagnostic_context.emitToken(path, firstExprToken(source_expr), "cannot create alias to packed field `{s}` in safe code", .{field.field});
                                return SemaError.SemanticFailed;
                            }
                            current_type = resolved.field_type_id;
                            break :blk .{ .field = .{
                                .struct_decl_id = resolved.struct_decl_id,
                                .struct_name = resolved.struct_name,
                                .field = field.field,
                            } };
                        },
                        .index => |index_expr| blk: {
                            if (try type_resolution.typeIndexAccessRole(typeConstructionContext(context), current_type)) |_| {} else {
                                try context.diagnostic_context.emitToken(path, firstExprToken(source_expr), "alias pointer borrowing requires an indexable local place", .{});
                                return SemaError.SemanticFailed;
                            }
                            const lowered_index = try lowerExpr(context, allocator, path, program, current_module, globals, locals, index_expr.index, try canonicalInferredIntegerTypeId(context));
                            try expectType(context, path, firstExprToken(index_expr.index), try canonicalInferredIntegerTypeId(context), lowered_index.type_id);
                            const role = (try type_resolution.typeIndexAccessRole(typeConstructionContext(context), current_type)) orelse unreachable;
                            current_type = role.value_type_id;
                            break :blk .{ .index = lowered_index.expr };
                        },
                    });
                }
                switch (sir_steps.items[sir_steps.items.len - 1]) {
                    .field => {
                        ref_expr.* = .{ .ref_path_local = .{
                            .local_name = root_name.text,
                            .steps = try sir_steps.toOwnedSlice(allocator),
                        } };
                    },
                    .index => |final_index| {
                        const prefix_steps = try allocator.alloc(sir.TakePathStep, sir_steps.items.len - 1);
                        @memcpy(prefix_steps, sir_steps.items[0 .. sir_steps.items.len - 1]);
                        sir_steps.items.len = 0;
                        sir_steps.deinit(allocator);
                        ref_expr.* = .{ .ref_index_path_local = .{
                            .local_name = root_name.text,
                            .steps = prefix_steps,
                            .index = final_index,
                        } };
                    },
                }
                return ref_expr;
            }
            switch (step) {
                .field => |field| {
                    const current_type = try borrowedRootTypeForPath(context, local, source_expr);
                    if (canonicalTypeKind(context, current_type) == .@"union") {
                        const resolved = try typeUnionPayloadField(context, path, program, current_module, current_type, field.field, field.field_token);
                        ref_expr.* = .{ .ref_union_field_local = .{
                            .local_name = root_name.text,
                            .union_decl_id = resolved.union_decl_id,
                            .union_name = resolved.union_name,
                            .field = field.field,
                        } };
                        return ref_expr;
                    }
                    const resolved = try typeStructField(context, path, program, current_module, current_type, field.field, field.field_token);
                    if (resolved.decl.layout == .@"packed") {
                        try context.diagnostic_context.emitToken(path, firstExprToken(source_expr), "cannot create alias to packed field `{s}` in safe code", .{field.field});
                        return SemaError.SemanticFailed;
                    }
                    ref_expr.* = if (local.kind(context) == .owned)
                        .{ .ref_field_owned_local = .{
                            .local_name = root_name.text,
                            .struct_decl_id = resolved.struct_decl_id,
                            .struct_name = resolved.struct_name,
                            .field = field.field,
                        } }
                    else
                        .{ .ref_field_local = .{
                            .local_name = root_name.text,
                            .struct_decl_id = resolved.struct_decl_id,
                            .struct_name = resolved.struct_name,
                            .field = field.field,
                        } };
                    return ref_expr;
                },
                .index => |index| {
                    const lowered_index = try lowerExpr(context, allocator, path, program, current_module, globals, locals, index.index, try canonicalInferredIntegerTypeId(context));
                    errdefer lowered_index.expr.destroy(allocator);
                    try expectType(context, path, firstExprToken(index.index), try canonicalInferredIntegerTypeId(context), lowered_index.type_id);
                    const local_type = try borrowedRootTypeForPath(context, local, source_expr);
                    if (try type_resolution.typeIndexAccessRole(typeConstructionContext(context), local_type)) |_| {
                        ref_expr.* = .{ .ref_index_local = .{
                            .local_name = root_name.text,
                            .index = lowered_index.expr,
                        } };
                    } else {
                        try context.diagnostic_context.emitToken(path, firstExprToken(source_expr), "indexed alias requires an array, `[:]` array, or slice local", .{});
                        return SemaError.SemanticFailed;
                    }
                    return ref_expr;
                },
            }
        }

        pub fn lowerAddressOfRawFieldAlias(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            source_expr: *ast.Expr,
            reversed_steps: []const TakeAstStep,
        ) SemaError!?TypedExpr {
            const pointer_source = placeDerefOperand(source_expr) orelse return null;
            for (reversed_steps) |step| if (step == .index) return null;

            const pointer = try lowerExpr(context, allocator, path, program, current_module, globals, locals, pointer_source, null);
            var pointer_owned = true;
            errdefer if (pointer_owned) pointer.expr.destroy(allocator);
            const raw = switch (canonicalTypeNode(context, pointer.type_id).*) {
                .raw => |raw| raw,
                else => return null,
            };

            var current_type = raw.target;
            var current_expr = try allocator.create(sir.Expr);
            errdefer current_expr.destroy(allocator);
            current_expr.* = .{ .ref_raw_deref = .{
                .expr = pointer.expr,
                .is_volatile = raw.is_volatile,
            } };
            pointer_owned = false;
            if (reversed_steps.len != 0) {
                var root_typed = try makeTypedExprWithProvenance(
                    context,
                    current_expr,
                    try canonicalRefTypeIdForAccess(context, current_type, if (raw.is_const) .read_only else .writable),
                    .none(),
                );
                try finalizeAndRecordExprSemantics(context, path, program, current_module, &root_typed);
                if (semanticExprMetadata(context, pointer.expr)) |pointer_metadata| {
                    if (pointer_metadata.checked_place_root) |source| {
                        var deref_metadata = semanticExprMetadata(context, current_expr) orelse return error.SemanticFailed;
                        deref_metadata.checked_raw_deref = .{
                            .pointer_source = source,
                            .pointee_type_id = raw.target,
                            .is_volatile = raw.is_volatile,
                        };
                        try recordExprMetadata(context, current_expr, deref_metadata);
                    }
                }
            }

            var i: usize = reversed_steps.len;
            while (i > 0) {
                i -= 1;
                const field = reversed_steps[i].field;
                const resolved = try typeStructField(context, path, program, current_module, current_type, field.field, field.field_token);
                if (resolved.decl.layout == .@"packed") {
                    try context.diagnostic_context.emitToken(path, field.field_token, "cannot create alias to packed field `{s}` in safe code", .{field.field});
                    return SemaError.SemanticFailed;
                }
                const next = try allocator.create(sir.Expr);
                next.* = .{ .ref_field_expr = .{
                    .object = current_expr,
                    .struct_decl_id = resolved.struct_decl_id,
                    .struct_name = resolved.struct_name,
                    .field = field.field,
                } };
                current_expr = next;
                current_type = resolved.field_type_id;
                if (i != 0) {
                    var projected = try makeTypedExprWithProvenance(
                        context,
                        current_expr,
                        try canonicalRefTypeIdForAccess(context, current_type, if (raw.is_const) .read_only else .writable),
                        .none(),
                    );
                    try finalizeAndRecordExprSemantics(context, path, program, current_module, &projected);
                }
            }

            out.* = current_expr.*;
            allocator.destroy(current_expr);
            return try makeTypedExprWithProvenance(
                context,
                out,
                try canonicalRefTypeIdForAccess(context, current_type, if (raw.is_const) .read_only else .writable),
                .none(),
            );
        }

        pub fn lowerAddressOfIndexedPlaceAlias(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            source_expr: *ast.Expr,
        ) SemaError!TypedExpr {
            var reversed_steps: std.ArrayListUnmanaged(TakeAstStep) = .empty;
            defer reversed_steps.deinit(allocator);
            const root_name = try collectPlaceRootAndSteps(context, allocator, path, source_expr, &reversed_steps, "indexed alias requires an addressable place");
            const local = findLocal(locals, root_name.text) orelse {
                try context.diagnostic_context.emitToken(path, root_name.token, "unknown local `{s}`", .{root_name.text});
                return SemaError.SemanticFailed;
            };
            if (local.is_unavailable) {
                try emitUnavailableLocal(context, path, root_name.token, local, false);
                return SemaError.SemanticFailed;
            }
            const place = resolvePlace(context, program, current_module, globals, locals, source_expr) orelse
                return SemaError.SemanticFailed;
            var access = place.access;
            if (reversed_steps.items.len == 0 or reversed_steps.items[0] != .index) {
                try context.diagnostic_context.emitToken(path, firstExprToken(source_expr), "indexed alias requires a final indexed place", .{});
                return SemaError.SemanticFailed;
            }
            if (source_expr.* == .index) {
                if (try lowerIndexHookAlias(context, allocator, path, program, current_module, globals, locals, out, source_expr.index)) |hook_alias| {
                    return hook_alias;
                }
            }

            var sir_steps: std.ArrayListUnmanaged(sir.TakePathStep) = .empty;
            errdefer {
                for (sir_steps.items) |step| switch (step) {
                    .field => {},
                    .index => |index_expr| index_expr.destroy(allocator),
                };
                sir_steps.deinit(allocator);
            }

            var current_type = try borrowedRootTypeForPath(context, local, source_expr);
            var final_index: ?*sir.Expr = null;
            errdefer if (final_index) |index_expr| index_expr.destroy(allocator);
            var item_type: ?semantic_types.TypeId = null;

            var i: usize = reversed_steps.items.len;
            while (i > 0) {
                i -= 1;
                const is_final = i == 0;
                const ast_step = reversed_steps.items[i];
                switch (ast_step) {
                    .field => |field| {
                        const resolved = try typeStructField(context, path, program, current_module, current_type, field.field, field.field_token);
                        if (resolved.decl.layout == .@"packed") {
                            try context.diagnostic_context.emitToken(path, firstExprToken(source_expr), "cannot create alias to packed field `{s}` in safe code", .{field.field});
                            return SemaError.SemanticFailed;
                        }
                        try sir_steps.append(allocator, .{ .field = .{
                            .struct_decl_id = resolved.struct_decl_id,
                            .struct_name = resolved.struct_name,
                            .field = field.field,
                        } });
                        current_type = resolved.field_type_id;
                    },
                    .index => |index| {
                        if (canonicalTypeKind(context, current_type) == .slice and canonicalTypeNode(context, current_type).slice.is_const) {
                            access = access.constrain(.read_only);
                        }
                        if (try type_resolution.typeIndexAccessRole(typeConstructionContext(context), current_type)) |_| {} else {
                            try context.diagnostic_context.emitToken(path, firstExprToken(source_expr), "indexed alias requires an array, `[:]` array, or slice place", .{});
                            return SemaError.SemanticFailed;
                        }

                        const lowered_index = try lowerExpr(context, allocator, path, program, current_module, globals, locals, index.index, try canonicalInferredIntegerTypeId(context));
                        errdefer lowered_index.expr.destroy(allocator);
                        try expectType(context, path, firstExprToken(index.index), try canonicalInferredIntegerTypeId(context), lowered_index.type_id);
                        const role = (try type_resolution.typeIndexAccessRole(typeConstructionContext(context), current_type)) orelse unreachable;
                        current_type = role.value_type_id;
                        if (is_final) {
                            final_index = lowered_index.expr;
                            item_type = current_type;
                        } else {
                            try sir_steps.append(allocator, .{ .index = lowered_index.expr });
                        }
                    },
                }
            }

            if (access.allowsMutation()) {
                try rejectProjectedBindingMutableAliasCreation(context, path, program, current_module, globals, locals, source_expr, firstExprToken(source_expr));
            }
            const owned_steps = try sir_steps.toOwnedSlice(allocator);
            out.* = .{ .ref_index_path_local = .{
                .local_name = root_name.text,
                .steps = owned_steps,
                .index = final_index.?,
            } };
            final_index = null;
            return try makeTypedExprWithProvenance(
                context,
                out,
                try canonicalRefTypeIdForAccess(context, item_type.?, access),
                Provenance.fromNormalizedBorrowRoots(place.roots),
            );
        }

        pub fn lowerIndexHookAlias(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            index: ast.Index,
        ) SemaError!?TypedExpr {
            const object = try lowerExpr(context, allocator, path, program, current_module, globals, locals, index.object, null);
            defer object.expr.destroy(allocator);
            const method = selectSyntaxMethod(context, program, current_module, object.type_id, .index) orelse return null;

            var hook_args = [_]ast.CallArg{.{ .value = index.index }};
            const hook_call = ast.MethodCall{
                .object = index.object,
                .method = method.name,
                .method_token = index.token,
                .type_args = &.{},
                .args = &hook_args,
            };
            var lowered = try lowerMethodCallInternal(context, allocator, path, program, current_module, globals, locals, out, hook_call, null);
            errdefer {
                out.deinit(allocator);
                out.* = .none;
            }
            try finalizeAndRecordExprSemantics(context, path, program, current_module, &lowered);
            if (lowered.kind(context) != .ref) {
                try context.diagnostic_context.emitToken(path, index.token, "indexed alias through `syntax.index` requires a borrowed return type", .{});
                return SemaError.SemanticFailed;
            }
            return lowered;
        }

        pub fn lowerHookIndexedFieldAlias(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            source_expr: *ast.Expr,
        ) SemaError!?TypedExpr {
            if (source_expr.* != .field) return null;
            const field = source_expr.field;

            const base_expr = try allocator.create(sir.Expr);
            var base_expr_initialized = false;
            errdefer if (base_expr_initialized) base_expr.destroy(allocator) else allocator.destroy(base_expr);
            const base_alias = switch (field.object.*) {
                .index => try lowerIndexHookAlias(context, allocator, path, program, current_module, globals, locals, base_expr, field.object.index),
                .field => try lowerHookIndexedFieldAlias(context, allocator, path, program, current_module, globals, locals, base_expr, field.object),
                else => null,
            } orelse {
                allocator.destroy(base_expr);
                return null;
            };
            base_expr_initialized = true;
            if (base_alias.kind(context) != .ref) {
                base_alias.expr.destroy(allocator);
                return null;
            }

            const base_target = canonicalRefTarget(context, base_alias.type_id);
            const resolved = try typeStructField(context, path, program, current_module, base_target, field.field, field.field_token);
            if (resolved.decl.layout == .@"packed") {
                base_alias.expr.destroy(allocator);
                try context.diagnostic_context.emitToken(path, firstExprToken(source_expr), "cannot create alias to packed field `{s}` in safe code", .{field.field});
                return SemaError.SemanticFailed;
            }

            out.* = .{ .ref_field_expr = .{
                .object = base_alias.expr,
                .struct_decl_id = resolved.struct_decl_id,
                .struct_name = resolved.struct_name,
                .field = field.field,
            } };
            errdefer out.* = .none;
            const base_access: ownership_owner.Access = if (canonicalRefIsConst(context, base_alias.type_id)) .read_only else .writable;
            var projected = try makeTypedExprWithProvenance(
                context,
                out,
                try canonicalRefTypeIdForAccess(context, resolved.field_type_id, base_access),
                base_alias.provenance.derived(),
            );
            // Recursive callers use this reference as the next field's base.
            // Record every generated projection, not just the outer expression.
            try finalizeAndRecordExprSemantics(context, path, program, current_module, &projected);
            return projected;
        }

        pub fn lowerNewArray(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            new_array: ast.NewArray,
        ) SemaError!TypedExpr {
            const len = try lowerExpr(context, allocator, path, program, current_module, globals, locals, new_array.len, try canonicalInferredIntegerTypeId(context));
            errdefer len.expr.destroy(allocator);
            try expectType(context, path, firstExprToken(new_array.len), try canonicalInferredIntegerTypeId(context), len.type_id);

            const item_type = try parseCanonicalType(context, path, program, current_module, new_array.item_type);
            if (canonicalTypeKind(context, item_type) == .void or canonicalTypeKind(context, item_type) == .ref) {
                try context.diagnostic_context.emitToken(path, new_array.item_type.token, "invalid `[:]T` item type", .{});
                return SemaError.SemanticFailed;
            }

            out.* = .{ .new_array = .{
                .len = len.expr,
                .item_type_id = item_type,
            } };
            return makeTypedExprFromIdWithProvenance(out, try canonicalDenseArrayTypeId(context, item_type), len.provenance);
        }

        pub fn lowerNewSparse(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            new_sparse: ast.NewSparse,
        ) SemaError!TypedExpr {
            const capacity = try lowerExpr(context, allocator, path, program, current_module, globals, locals, new_sparse.capacity, try canonicalInferredIntegerTypeId(context));
            errdefer capacity.expr.destroy(allocator);
            try expectType(context, path, firstExprToken(new_sparse.capacity), try canonicalInferredIntegerTypeId(context), capacity.type_id);

            const item_type = try parseCanonicalType(context, path, program, current_module, new_sparse.item_type);
            if (canonicalTypeKind(context, item_type) == .void or canonicalTypeKind(context, item_type) == .ref) {
                try context.diagnostic_context.emitToken(path, new_sparse.item_type.token, "invalid `[;]T` item type", .{});
                return SemaError.SemanticFailed;
            }

            out.* = .{ .new_sparse = .{
                .capacity = capacity.expr,
                .item_type_id = item_type,
            } };
            return makeTypedExprFromIdWithProvenance(out, try canonicalSparseArrayTypeId(context, item_type), capacity.provenance);
        }

        pub fn lowerFixedArrayConstruct(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            construct: ast.FixedArrayConstruct,
        ) SemaError!TypedExpr {
            const item_type = try parseCanonicalType(context, path, program, current_module, construct.item_type);
            if (canonicalTypeKind(context, item_type) == .void or canonicalTypeKind(context, item_type) == .ref) {
                try context.diagnostic_context.emitToken(path, construct.item_type.token, "invalid fixed array item type", .{});
                return SemaError.SemanticFailed;
            }
            const array_type = try canonicalArrayTypeId(context, construct.len, item_type);
            if (construct.items.len == 0) {
                if (!try typeIsDefaultInitializable(context, path, program, item_type)) {
                    try context.diagnostic_context.emitToken(path, construct.item_type.token, "fixed array empty construction requires a default-initializable item type", .{});
                    return SemaError.SemanticFailed;
                }
                out.* = .{ .array_default = .{
                    .len = construct.len,
                    .item_type_id = item_type,
                } };
                return try makeTypedExpr(context, out, array_type);
            }
            if (construct.items.len != construct.len) {
                try context.diagnostic_context.emitToken(path, construct.token, "fixed array construction expects {d} items, got {d}", .{ construct.len, construct.items.len });
                return SemaError.SemanticFailed;
            }

            var items: std.ArrayListUnmanaged(*sir.Expr) = .empty;
            var combined_provenance = Provenance.none();
            errdefer {
                for (items.items) |item| item.destroy(allocator);
                items.deinit(allocator);
            }
            for (construct.items) |item| {
                const value = try lowerExprInContext(context, allocator, path, program, current_module, globals, locals, item, item_type);
                errdefer value.expr.destroy(allocator);
                try expectType(context, path, firstExprToken(item), item_type, value.type_id);
                combined_provenance = Provenance.combine(combined_provenance, value.provenance);
                try items.append(allocator, value.expr);
            }

            const owned_items = try items.toOwnedSlice(allocator);
            out.* = .{ .array_literal = .{
                .len = construct.len,
                .item_type_id = item_type,
                .items = owned_items,
            } };
            return try makeTypedExprWithProvenance(context, out, array_type, combined_provenance);
        }

        pub fn lowerTypedSequenceLiteral(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            literal: ast.TypedSequenceLiteral,
            expected_type_id: ?semantic_types.TypeId,
        ) SemaError!TypedExpr {
            const target_type_id = try storageMarkerTargetType(context, path, program, current_module, literal.target, expected_type_id);

            if (type_resolution.denseStorageLiteralItemType(typeConstructionContext(context), target_type_id)) |item_type_id| {
                return try lowerBuiltinSequenceLiteralExpr(
                    context,
                    allocator,
                    path,
                    program,
                    current_module,
                    globals,
                    locals,
                    out,
                    literal.items,
                    target_type_id,
                    item_type_id,
                    literal.storage_capacity,
                    .dense_array,
                );
            }

            switch (canonicalTypeNode(context, target_type_id).*) {
                .array => |array_type| {
                    const item_type_id = array_type.item;
                    if (literal.items.len == 0) {
                        if (!try typeIsDefaultInitializable(context, path, program, item_type_id)) {
                            try context.diagnostic_context.emitToken(path, literal.token, "fixed array empty construction requires a default-initializable item type", .{});
                            return SemaError.SemanticFailed;
                        }
                        out.* = .{ .array_default = .{
                            .len = array_type.len,
                            .item_type_id = item_type_id,
                        } };
                        return makeTypedExprFromId(out, target_type_id);
                    }
                    if (literal.items.len != array_type.len) {
                        try context.diagnostic_context.emitToken(path, literal.token, "array literal expects {d} items, got {d}", .{ array_type.len, literal.items.len });
                        return SemaError.SemanticFailed;
                    }

                    var items: std.ArrayListUnmanaged(*sir.Expr) = .empty;
                    var combined_provenance = Provenance.none();
                    errdefer {
                        for (items.items) |item| item.destroy(allocator);
                        items.deinit(allocator);
                    }

                    for (literal.items) |item| {
                        const value = try lowerExprInContext(context, allocator, path, program, current_module, globals, locals, item, item_type_id);
                        errdefer value.expr.destroy(allocator);
                        try expectType(context, path, firstExprToken(item), item_type_id, value.type_id);
                        try lowerImplicitHandoff(context, path, program, locals, item, item_type_id, value.expr);
                        try markCheckedNamedHandoff(context, path, program, @constCast(locals), item, value.expr, item_type_id);
                        combined_provenance = Provenance.combine(combined_provenance, value.provenance);
                        try items.append(allocator, value.expr);
                    }

                    const owned_items = try items.toOwnedSlice(allocator);
                    out.* = .{ .array_literal = .{
                        .len = array_type.len,
                        .item_type_id = item_type_id,
                        .items = owned_items,
                    } };
                    return makeTypedExprFromIdWithProvenance(out, target_type_id, combined_provenance);
                },
                .dense_array => |item_type_id| {
                    if (literal.storage_capacity) |capacity| {
                        if (capacity < literal.items.len) {
                            try context.diagnostic_context.emitToken(path, literal.token, "dense storage capacity {d} is smaller than initializer length {d}", .{ capacity, literal.items.len });
                            return SemaError.SemanticFailed;
                        }
                    }
                    var items: std.ArrayListUnmanaged(*sir.Expr) = .empty;
                    var combined_provenance = Provenance.none();
                    errdefer {
                        for (items.items) |item| item.destroy(allocator);
                        items.deinit(allocator);
                    }

                    for (literal.items) |item| {
                        const value = try lowerExprInContext(context, allocator, path, program, current_module, globals, locals, item, item_type_id);
                        errdefer value.expr.destroy(allocator);
                        try expectType(context, path, firstExprToken(item), item_type_id, value.type_id);
                        try rejectProjectedResourceTransferForTypedValue(context, path, program, firstExprToken(item), value, item_type_id, "sequence literal element");
                        try lowerImplicitHandoff(context, path, program, locals, item, item_type_id, value.expr);
                        try markCheckedNamedHandoff(context, path, program, @constCast(locals), item, value.expr, item_type_id);
                        combined_provenance = Provenance.combine(combined_provenance, value.provenance);
                        try items.append(allocator, value.expr);
                    }

                    const owned_items = try items.toOwnedSlice(allocator);
                    out.* = .{ .dense_array_literal = .{
                        .len = literal.items.len,
                        .capacity = literal.storage_capacity,
                        .item_type_id = item_type_id,
                        .items = owned_items,
                    } };
                    return makeTypedExprFromIdWithProvenance(out, target_type_id, combined_provenance);
                },
                .sparse_array => |item_type_id| {
                    const capacity = literal.storage_capacity orelse literal.items.len;
                    if (capacity < literal.items.len) {
                        try context.diagnostic_context.emitToken(path, literal.token, "sparse storage capacity {d} is smaller than initializer length {d}", .{ capacity, literal.items.len });
                        return SemaError.SemanticFailed;
                    }
                    if (literal.items.len == 0) {
                        const capacity_expr = try allocator.create(sir.Expr);
                        capacity_expr.* = .{ .int = .{
                            .value = @intCast(capacity),
                            .type_name = null,
                        } };
                        var capacity_typed = makeTypedExprFromId(capacity_expr, try canonicalInferredIntegerTypeId(context));
                        try finalizeAndRecordExprSemantics(context, path, program, current_module, &capacity_typed);
                        out.* = .{ .new_sparse = .{
                            .capacity = capacity_expr,
                            .item_type_id = item_type_id,
                        } };
                        return makeTypedExprFromId(out, target_type_id);
                    }

                    const slot_type_id = try canonicalOptionalTypeId(context, item_type_id);
                    var items: std.ArrayListUnmanaged(*sir.Expr) = .empty;
                    var combined_provenance = Provenance.none();
                    errdefer {
                        for (items.items) |item| item.destroy(allocator);
                        items.deinit(allocator);
                    }

                    for (literal.items) |item| {
                        const value = try lowerExprInContext(context, allocator, path, program, current_module, globals, locals, item, slot_type_id);
                        errdefer value.expr.destroy(allocator);
                        try expectType(context, path, firstExprToken(item), slot_type_id, value.type_id);
                        try rejectProjectedResourceTransferForTypedValue(context, path, program, firstExprToken(item), value, slot_type_id, "sparse literal element");
                        try lowerImplicitHandoff(context, path, program, locals, item, slot_type_id, value.expr);
                        try markCheckedNamedHandoff(context, path, program, @constCast(locals), item, value.expr, slot_type_id);
                        combined_provenance = Provenance.combine(combined_provenance, value.provenance);
                        try items.append(allocator, value.expr);
                    }

                    const owned_items = try items.toOwnedSlice(allocator);
                    out.* = .{ .sparse_literal = .{
                        .capacity = capacity,
                        .len = literal.items.len,
                        .item_type_id = item_type_id,
                        .items = owned_items,
                    } };
                    return makeTypedExprFromIdWithProvenance(out, target_type_id, combined_provenance);
                },
                else => {
                    try context.diagnostic_context.emitToken(path, literal.token, "typed `[...]` construction requires a fixed array, `[:]` array, or `[;]` storage target", .{});
                    return SemaError.SemanticFailed;
                },
            }
        }

        pub fn lowerHomogeneousLiteralItems(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            literal_items: []const *ast.Expr,
            item_type_id: semantic_types.TypeId,
            first: ?TypedExpr,
        ) SemaError!LoweredHomogeneousLiteralItems {
            var items: std.ArrayListUnmanaged(*sir.Expr) = .empty;
            var combined_provenance = Provenance.none();
            errdefer {
                for (items.items) |item| item.destroy(allocator);
                items.deinit(allocator);
            }
            for (literal_items, 0..) |item, index| {
                const value = if (index == 0 and first != null) first.? else try lowerExprInContext(context, allocator, path, program, current_module, globals, locals, item, item_type_id);
                errdefer value.expr.destroy(allocator);
                try expectType(context, path, firstExprToken(item), item_type_id, value.type_id);
                try rejectProjectedResourceTransferForTypedValue(context, path, program, firstExprToken(item), value, item_type_id, "sequence literal element");
                try lowerImplicitHandoff(context, path, program, locals, item, item_type_id, value.expr);
                try markCheckedNamedHandoff(context, path, program, @constCast(locals), item, value.expr, item_type_id);
                combined_provenance = Provenance.combine(combined_provenance, value.provenance);
                try items.append(allocator, value.expr);
            }
            return .{
                .items = try items.toOwnedSlice(allocator),
                .combined_provenance = combined_provenance,
            };
        }

        pub fn lowerBuiltinSequenceLiteralExpr(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            literal_items: []const *ast.Expr,
            target_type_id: semantic_types.TypeId,
            item_type_id: semantic_types.TypeId,
            storage_capacity: ?usize,
            kind: BuiltinSequenceLiteralKind,
        ) SemaError!TypedExpr {
            const lowered = try lowerHomogeneousLiteralItems(context, allocator, path, program, current_module, globals, locals, literal_items, item_type_id, null);
            switch (kind) {
                .dense_array => {
                    if (storage_capacity) |capacity| {
                        if (capacity < literal_items.len) {
                            for (lowered.items) |item| item.destroy(allocator);
                            allocator.free(lowered.items);
                            try context.diagnostic_context.emitToken(path, firstExprToken(literal_items[0]), "dense storage capacity {d} is smaller than initializer length {d}", .{ capacity, literal_items.len });
                            return SemaError.SemanticFailed;
                        }
                    }
                    out.* = .{ .dense_array_literal = .{
                        .len = literal_items.len,
                        .capacity = storage_capacity,
                        .item_type_id = item_type_id,
                        .items = lowered.items,
                    } };
                },
            }
            return makeTypedExprFromIdWithProvenance(out, target_type_id, lowered.combined_provenance);
        }

        pub fn lowerKeyedLiteral(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            literal: ast.KeyedLiteral,
            expected_type_id: ?semantic_types.TypeId,
        ) SemaError!TypedExpr {
            const target_type_id = if (literal.target) |target|
                try storageMarkerTargetType(context, path, program, current_module, target, expected_type_id)
            else
                expected_type_id orelse {
                    try context.diagnostic_context.emitToken(path, literal.token, "cannot infer keyed literal type", .{});
                    return SemaError.SemanticFailed;
                };
            switch (canonicalTypeKind(context, target_type_id)) {
                .@"struct" => {
                    if (literal.storage_capacity != null) {
                        try context.diagnostic_context.emitToken(path, literal.token, "struct keyed literal does not accept a storage capacity", .{});
                        return SemaError.SemanticFailed;
                    }
                    return try lowerStructKeyedLiteral(context, allocator, path, program, current_module, globals, locals, out, literal, target_type_id);
                },
                .sparse_array => {
                    const capacity = literal.storage_capacity orelse try inferSparseKeyedLiteralCapacity(context, path, literal);
                    return try lowerSparseKeyedLiteral(context, allocator, path, program, current_module, globals, locals, out, literal, target_type_id, capacity);
                },
                else => {
                    try context.diagnostic_context.emitToken(path, literal.token, "keyed literal requires a struct or `[;]` storage target", .{});
                    return SemaError.SemanticFailed;
                },
            }
        }

        pub fn lowerSparseKeyedLiteral(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            literal: ast.KeyedLiteral,
            target_type: semantic_types.TypeId,
            capacity: usize,
        ) SemaError!TypedExpr {
            const item_type = canonicalTypeNode(context, target_type).sparse_array;
            var entries: std.ArrayListUnmanaged(sir.SparseKeyedLiteralEntry) = .empty;
            var combined_provenance = Provenance.none();
            errdefer {
                for (entries.items) |entry| {
                    entry.index.destroy(allocator);
                    entry.value.destroy(allocator);
                }
                entries.deinit(allocator);
            }

            for (literal.entries) |entry| {
                if (entry.key.* == .int) {
                    const index = entry.key.int.value;
                    if (index < 0 or index >= capacity) {
                        try context.diagnostic_context.emitToken(path, entry.key.int.token, "sparse storage keyed index {d} is outside capacity {d}", .{ index, capacity });
                        return SemaError.SemanticFailed;
                    }
                }
                const index = try lowerExpr(context, allocator, path, program, current_module, globals, locals, entry.key, try canonicalInferredIntegerTypeId(context));
                errdefer index.expr.destroy(allocator);
                try expectType(context, path, firstExprToken(entry.key), try canonicalInferredIntegerTypeId(context), index.type_id);
                const value = try lowerExprInContext(context, allocator, path, program, current_module, globals, locals, entry.value, item_type);
                errdefer value.expr.destroy(allocator);
                try expectType(context, path, firstExprToken(entry.value), item_type, value.type_id);
                try rejectProjectedResourceTransferForTypedValue(context, path, program, firstExprToken(entry.value), value, item_type, "sparse literal element");
                try lowerImplicitHandoff(context, path, program, locals, entry.value, item_type, value.expr);
                try markCheckedNamedHandoff(context, path, program, @constCast(locals), entry.value, value.expr, item_type);
                combined_provenance = Provenance.combine(Provenance.combine(combined_provenance, index.provenance), value.provenance);
                try entries.append(allocator, .{
                    .index = index.expr,
                    .value = value.expr,
                });
            }

            const owned_entries = try entries.toOwnedSlice(allocator);
            out.* = .{ .sparse_keyed_literal = .{
                .capacity = capacity,
                .item_type_id = item_type,
                .entries = owned_entries,
            } };
            return try makeTypedExprWithProvenance(context, out, target_type, combined_provenance);
        }

        fn lowerStructDefaultField(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            decl: StructLookup,
            globals: []const GlobalBinding,
            field_name: []const u8,
            default_value: *ast.Expr,
        ) SemaError!TypedExpr {
            const decl_field = lookupStructField(decl, field_name) orelse return error.SemanticFailed;
            const field_type = try structFieldTypeId(context, path, program, decl, decl_field);
            const value = try lowerExprInContext(context, allocator, path, program, decl.module_name, globals, &.{}, default_value, field_type);
            errdefer value.expr.destroy(allocator);
            try expectType(context, path, firstExprToken(default_value), field_type, value.type_id);
            try rejectProjectedResourceTransferForTypedValue(context, path, program, firstExprToken(default_value), value, field_type, "struct field default");
            return value;
        }

        pub fn lowerStructKeyedLiteral(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            literal: ast.KeyedLiteral,
            target_type: semantic_types.TypeId,
        ) SemaError!TypedExpr {
            const type_name = canonicalNominalDeclName(context, program, target_type) orelse return error.SemanticFailed;
            const decl = canonicalStructLookup(context, program, target_type) orelse {
                try context.diagnostic_context.emitToken(path, literal.token, "unknown struct `{s}`", .{type_name});
                return SemaError.SemanticFailed;
            };
            const field_count = switch (decl.fields) {
                .ast_fields => |fields| fields.len,
                .inst_fields => |fields| fields.len,
            };
            if (literal.entries.len > field_count) {
                try context.diagnostic_context.emitToken(path, literal.token, "struct `{s}` expects {d} fields, got {d}", .{ type_name, field_count, literal.entries.len });
                return SemaError.SemanticFailed;
            }
            for (literal.entries, 0..) |entry, index| {
                if (entry.key.* != .name) continue;
                for (literal.entries[0..index]) |previous| {
                    if (previous.key.* == .name and std.mem.eql(u8, previous.key.name.text, entry.key.name.text)) {
                        try context.diagnostic_context.emitToken(path, firstExprToken(entry.key), "duplicate struct field `{s}`", .{entry.key.name.text});
                        return SemaError.SemanticFailed;
                    }
                }
            }

            var fields: std.ArrayListUnmanaged(sir.StructLiteralField) = .empty;
            var combined_provenance = Provenance.none();
            errdefer {
                for (fields.items) |field| field.value.destroy(allocator);
                fields.deinit(allocator);
            }

            switch (decl.fields) {
                .ast_fields => |ast_fields| for (ast_fields) |decl_field| {
                    if (!canAccessDecl(context, current_module, decl.module_name, decl_field.is_pub)) {
                        try context.diagnostic_context.emitToken(path, literal.token, "field `{s}` of struct `{s}` is not public", .{ decl_field.name, type_name });
                        return SemaError.SemanticFailed;
                    }
                    if (findKeyedStructEntry(literal.entries, decl_field.name) == null and decl_field.default_value == null) {
                        try context.diagnostic_context.emitToken(path, literal.token, "missing field `{s}` for struct `{s}`", .{ decl_field.name, type_name });
                        return SemaError.SemanticFailed;
                    }
                },
                .inst_fields => |inst_fields| for (inst_fields) |decl_field| {
                    if (!canAccessDecl(context, current_module, decl.module_name, decl_field.is_pub)) {
                        try context.diagnostic_context.emitToken(path, literal.token, "field `{s}` of struct `{s}` is not public", .{ decl_field.name, type_name });
                        return SemaError.SemanticFailed;
                    }
                    if (findKeyedStructEntry(literal.entries, decl_field.name) == null and decl_field.default_value == null) {
                        try context.diagnostic_context.emitToken(path, literal.token, "missing field `{s}` for struct `{s}`", .{ decl_field.name, type_name });
                        return SemaError.SemanticFailed;
                    }
                },
            }

            for (literal.entries) |literal_entry| {
                if (literal_entry.key.* != .name) {
                    try context.diagnostic_context.emitToken(path, firstExprToken(literal_entry.key), "struct literal field key must be a field name", .{});
                    return SemaError.SemanticFailed;
                }
                const field_name = literal_entry.key.name.text;
                const decl_field = lookupStructField(decl, field_name) orelse {
                    try context.diagnostic_context.emitToken(path, firstExprToken(literal_entry.key), "struct `{s}` has no field `{s}`", .{ type_name, field_name });
                    return SemaError.SemanticFailed;
                };
                const field_type = try structFieldTypeId(context, path, program, decl, decl_field);
                const value = try lowerExprInContext(context, allocator, path, program, current_module, globals, locals, literal_entry.value, field_type);
                errdefer value.expr.destroy(allocator);
                try expectType(context, path, firstExprToken(literal_entry.value), field_type, value.type_id);
                try rejectProjectedResourceTransferForTypedValue(context, path, program, firstExprToken(literal_entry.value), value, field_type, "struct literal field");
                try lowerImplicitHandoff(context, path, program, locals, literal_entry.value, field_type, value.expr);
                try markCheckedNamedHandoff(context, path, program, @constCast(locals), literal_entry.value, value.expr, field_type);
                combined_provenance = Provenance.combine(combined_provenance, value.provenance);
                try fields.append(allocator, .{ .name = field_name, .value = value.expr });
            }

            switch (decl.fields) {
                .ast_fields => |decl_fields| for (decl_fields) |decl_field| {
                    if (findKeyedStructEntry(literal.entries, decl_field.name) != null) continue;
                    const default_value = decl_field.default_value orelse continue;
                    const value = try lowerStructDefaultField(context, allocator, path, program, decl, globals, decl_field.name, default_value);
                    errdefer value.expr.destroy(allocator);
                    combined_provenance = Provenance.combine(combined_provenance, value.provenance);
                    try fields.append(allocator, .{ .name = decl_field.name, .value = value.expr });
                },
                .inst_fields => |decl_fields| for (decl_fields) |decl_field| {
                    if (findKeyedStructEntry(literal.entries, decl_field.name) != null) continue;
                    const default_value = decl_field.default_value orelse continue;
                    const value = try lowerStructDefaultField(context, allocator, path, program, decl, globals, decl_field.name, default_value);
                    errdefer value.expr.destroy(allocator);
                    combined_provenance = Provenance.combine(combined_provenance, value.provenance);
                    try fields.append(allocator, .{ .name = decl_field.name, .value = value.expr });
                },
            }

            const owned_decl_id = try registeredOrGeneratedDeclId(context, decl.module_name, null, type_name, .@"struct");
            const owned_fields = try fields.toOwnedSlice(allocator);
            out.* = .{ .struct_literal = .{
                .decl_id = owned_decl_id,
                .type_name = type_name,
                .type_module_name = decl.module_name,
                .fields = owned_fields,
            } };
            return try makeTypedExprWithProvenance(context, out, target_type, combined_provenance);
        }

        pub fn lowerOwnedStructLiteral(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            literal: ast.StructLiteral,
        ) SemaError!TypedExpr {
            const type_name = literal.type_name orelse {
                try context.diagnostic_context.emitToken(path, literal.type_token, "`new` requires an explicit type name", .{});
                return SemaError.SemanticFailed;
            };

            const struct_type = try parseType(context, path, program, current_module, .{
                .is_ref = false,
                .is_owned = false,
                .is_raw = false,
                .is_volatile_raw = false,
                .is_optional = false,
                .is_slice = false,
                .array_len = null,
                .name = type_name,
                .args = literal.type_args,
                .token = literal.type_token,
            });
            if (canonicalTypeKind(context, struct_type) != .@"struct") {
                // At the definition site a binder has no struct layout yet. The body's
                // constructor use is recorded from the lowered literal, and every
                // specialization re-lowers this literal against the substituted struct.
                if (type_resolution.containsDefinitionSiteBinder(canonicalTypeInterner(context), struct_type)) {
                    var deferred_fields: std.ArrayListUnmanaged(sir.StructLiteralField) = .empty;
                    errdefer {
                        for (deferred_fields.items) |field| field.value.destroy(allocator);
                        deferred_fields.deinit(allocator);
                    }
                    var deferred_provenance = Provenance.none();
                    for (literal.fields) |literal_field| {
                        const value = try lowerExprInContext(context, allocator, path, program, current_module, globals, locals, literal_field.value, null);
                        try deferred_fields.append(allocator, .{ .name = literal_field.name, .value = value.expr });
                        deferred_provenance = Provenance.combine(deferred_provenance, value.provenance);
                    }
                    out.* = .{ .new_owned = .{
                        .decl_id = null,
                        .type_name = type_name,
                        .type_module_name = current_module,
                        .fields = try deferred_fields.toOwnedSlice(allocator),
                    } };
                    return try makeTypedExprWithProvenance(context, out, try canonicalOwnedTypeId(context, struct_type), deferred_provenance);
                }
                try context.diagnostic_context.emitToken(path, literal.type_token, "`new` requires a struct type", .{});
                return SemaError.SemanticFailed;
            }
            const concrete_name = canonicalNominalDeclName(context, program, struct_type) orelse return error.SemanticFailed;

            const decl = canonicalStructLookup(context, program, struct_type) orelse {
                try context.diagnostic_context.emitToken(path, literal.type_token, "unknown struct `{s}`", .{concrete_name});
                return SemaError.SemanticFailed;
            };
            const field_count = switch (decl.fields) {
                .ast_fields => |fields| fields.len,
                .inst_fields => |fields| fields.len,
            };
            if (literal.fields.len > field_count) {
                try context.diagnostic_context.emitToken(path, literal.type_token, "struct `{s}` expects {d} fields, got {d}", .{ concrete_name, field_count, literal.fields.len });
                return SemaError.SemanticFailed;
            }
            for (literal.fields, 0..) |field, index| {
                for (literal.fields[0..index]) |previous| {
                    if (std.mem.eql(u8, previous.name, field.name)) {
                        try context.diagnostic_context.emitToken(path, field.name_token, "duplicate struct field `{s}`", .{field.name});
                        return SemaError.SemanticFailed;
                    }
                }
            }

            var fields: std.ArrayListUnmanaged(sir.StructLiteralField) = .empty;
            var combined_provenance = Provenance.none();
            errdefer {
                for (fields.items) |field| field.value.destroy(allocator);
                fields.deinit(allocator);
            }

            switch (decl.fields) {
                .ast_fields => |ast_fields| for (ast_fields) |decl_field| {
                    if (!canAccessDecl(context, current_module, decl.module_name, decl_field.is_pub)) {
                        try context.diagnostic_context.emitToken(path, literal.type_token, "field `{s}` of struct `{s}` is not public", .{ decl_field.name, concrete_name });
                        return SemaError.SemanticFailed;
                    }
                    if (findLiteralField(literal.fields, decl_field.name) == null and decl_field.default_value == null) {
                        try context.diagnostic_context.emitToken(path, literal.type_token, "missing field `{s}` for struct `{s}`", .{ decl_field.name, concrete_name });
                        return SemaError.SemanticFailed;
                    }
                },
                .inst_fields => |inst_fields| for (inst_fields) |decl_field| {
                    if (!canAccessDecl(context, current_module, decl.module_name, decl_field.is_pub)) {
                        try context.diagnostic_context.emitToken(path, literal.type_token, "field `{s}` of struct `{s}` is not public", .{ decl_field.name, concrete_name });
                        return SemaError.SemanticFailed;
                    }
                    if (findLiteralField(literal.fields, decl_field.name) == null and decl_field.default_value == null) {
                        try context.diagnostic_context.emitToken(path, literal.type_token, "missing field `{s}` for struct `{s}`", .{ decl_field.name, concrete_name });
                        return SemaError.SemanticFailed;
                    }
                },
            }

            for (literal.fields) |literal_field| {
                const decl_field = lookupStructField(decl, literal_field.name) orelse {
                    try context.diagnostic_context.emitToken(path, literal_field.name_token, "struct `{s}` has no field `{s}`", .{ concrete_name, literal_field.name });
                    return SemaError.SemanticFailed;
                };
                const field_type = try structFieldTypeId(context, path, program, decl, decl_field);
                const value = try lowerExprInContext(context, allocator, path, program, current_module, globals, locals, literal_field.value, field_type);
                errdefer value.expr.destroy(allocator);
                try expectType(context, path, literal_field.name_token, field_type, value.type_id);
                try rejectProjectedResourceTransferForTypedValue(context, path, program, literal_field.name_token, value, field_type, "struct literal field");
                try lowerImplicitHandoff(context, path, program, locals, literal_field.value, field_type, value.expr);
                try markCheckedNamedHandoff(context, path, program, @constCast(locals), literal_field.value, value.expr, field_type);
                combined_provenance = Provenance.combine(combined_provenance, value.provenance);
                try fields.append(allocator, .{ .name = literal_field.name, .value = value.expr });
            }

            switch (decl.fields) {
                .ast_fields => |decl_fields| for (decl_fields) |decl_field| {
                    if (findLiteralField(literal.fields, decl_field.name) != null) continue;
                    const default_value = decl_field.default_value orelse continue;
                    const value = try lowerStructDefaultField(context, allocator, path, program, decl, globals, decl_field.name, default_value);
                    errdefer value.expr.destroy(allocator);
                    combined_provenance = Provenance.combine(combined_provenance, value.provenance);
                    try fields.append(allocator, .{ .name = decl_field.name, .value = value.expr });
                },
                .inst_fields => |decl_fields| for (decl_fields) |decl_field| {
                    if (findLiteralField(literal.fields, decl_field.name) != null) continue;
                    const default_value = decl_field.default_value orelse continue;
                    const value = try lowerStructDefaultField(context, allocator, path, program, decl, globals, decl_field.name, default_value);
                    errdefer value.expr.destroy(allocator);
                    combined_provenance = Provenance.combine(combined_provenance, value.provenance);
                    try fields.append(allocator, .{ .name = decl_field.name, .value = value.expr });
                },
            }

            const owned_fields = try fields.toOwnedSlice(allocator);
            out.* = .{ .new_owned = .{
                .decl_id = canonicalNominalDeclId(context, struct_type) orelse try registeredOrGeneratedDeclId(context, decl.module_name, null, concrete_name, .@"struct"),
                .type_name = concrete_name,
                .type_module_name = decl.module_name,
                .fields = owned_fields,
            } };
            return try makeTypedExprWithProvenance(context, out, try canonicalOwnedTypeId(context, struct_type), combined_provenance);
        }

        pub fn lowerSequenceFactoryLiteral(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            literal: ast.ArrayLiteral,
            target: semantic_types.TypeId,
        ) SemaError!?TypedExpr {
            var selected: ?ast.Function = null;
            var selected_args: []semantic_types.GenericArgument = &.{};
            defer context.allocator.free(selected_args);
            var first: ?TypedExpr = null;
            defer if (first) |value| value.expr.destroy(allocator);
            for (program.functions) |factory| {
                if (!factory.is_sequence_literal_factory or !sequenceFactoryVisible(context, program, current_module, factory)) continue;
                const bindings = try context.allocator.alloc(?semantic_types.GenericArgument, factory.type_params.len);
                defer context.allocator.free(bindings);
                @memset(bindings, null);
                if (!try matchSequenceReturn(context, path, program, factory.module_name, factory.return_type.?, target, factory.type_params, bindings)) continue;
                var missing = false;
                for (bindings) |binding| {
                    if (binding == null) missing = true;
                }
                if (missing and literal.items.len != 0) {
                    if (first == null) first = try lowerExpr(context, allocator, path, program, current_module, globals, locals, literal.items[0], null);
                    if (!try matchSequenceReturn(context, path, program, factory.module_name, factory.params[0].type_name.args[0], first.?.type_id, factory.type_params, bindings)) continue;
                }
                const args = try context.allocator.alloc(semantic_types.GenericArgument, bindings.len);
                defer context.allocator.free(args);
                for (bindings, factory.type_params, 0..) |binding, param, index| {
                    args[index] = binding orelse {
                        try context.diagnostic_context.emitToken(path, literal.token, "attribute `syntax.sequence_literal` cannot infer generic parameter `{s}` of factory `{s}`", .{ param.name, factory.name });
                        return SemaError.SemanticFailed;
                    };
                }
                if (!try protocols.genericConditionsSatisfied(SemaContext, typeIsOwnedForProtocol, context, path, program, factory.module_name, factory.type_params, args)) continue;
                if (try parseTypeWithBindings(context, path, program, factory.module_name, factory.return_type.?, null, factory.type_params, args) != target) continue;
                if (selected) |previous| {
                    try context.diagnostic_context.emitToken(path, literal.token, "ambiguous sequence literal: factories `{s}.{s}` and `{s}.{s}`", .{ previous.module_name, previous.name, factory.module_name, factory.name });
                    return SemaError.SemanticFailed;
                }
                selected = factory;
                selected_args = try context.allocator.dupe(semantic_types.GenericArgument, args);
            }
            const factory = selected orelse return null;
            for (factory.type_params, selected_args) |param, arg| {
                if (arg == .type) try protocols.expectGenericParamProtocolConformance(SemaContext, typeIsOwnedForProtocol, context, path, program, factory.module_name, param, literal.token, arg.type);
            }
            const storage_type = try parseTypeWithBindings(context, path, program, factory.module_name, factory.params[0].type_name, null, factory.type_params, selected_args);
            var storage_ast: ast.Expr = .{ .array_literal = literal };
            const original_args = [_]ast.CallArg{.{ .value = &storage_ast }};
            try rejectBorrowedCallStateEscapes(context, path, program, current_module, globals, locals, &original_args, factory, factory.type_params, selected_args);
            const call_args = try allocator.alloc(sir.CallArg, 1);
            errdefer allocator.free(call_args);
            var callee = factory.name;
            var callee_module = factory.module_name;
            var provenance = Provenance.none();
            if (factory.type_params.len == 0 and first == null) {
                call_args[0] = try lowerCallArg(context, allocator, path, program, current_module, globals, locals, original_args[0], storage_type, null);
                errdefer call_args[0].deinit(allocator);
                provenance = try inferredCallReturnProvenance(context, path, program, current_module, globals, locals, target, &original_args, factory, null, null);
            } else {
                const storage = if (first != null) blk: {
                    const storage_expr = try allocator.create(sir.Expr);
                    errdefer allocator.destroy(storage_expr);
                    const staged = first;
                    first = null;
                    const item_type = canonicalTypeNode(context, storage_type).dense_array;
                    const lowered = try lowerHomogeneousLiteralItems(context, allocator, path, program, current_module, globals, locals, literal.items, item_type, staged);
                    errdefer {
                        for (lowered.items) |item| item.destroy(allocator);
                        allocator.free(lowered.items);
                    }
                    storage_expr.* = .{ .dense_array_literal = .{ .len = literal.items.len, .item_type_id = item_type, .items = lowered.items } };
                    var typed = makeTypedExprFromIdWithProvenance(storage_expr, storage_type, lowered.combined_provenance);
                    try finalizeAndRecordExprSemantics(context, path, program, current_module, &typed);
                    break :blk typed;
                } else try lowerExprInContext(context, allocator, path, program, current_module, globals, locals, &storage_ast, storage_type);
                errdefer storage.expr.destroy(allocator);
                if (factory.type_params.len == 0) {
                    provenance = try inferredCallReturnProvenance(context, path, program, current_module, globals, locals, target, &original_args, factory, null, null);
                    call_args[0] = .{ .value = storage.expr };
                } else {
                    const concrete = try instantiateGenericFunctionFromResolvedCall(context, allocator, path, program, current_module, globals, locals, literal.token, factory, selected_args, &original_args, &.{storage});
                    defer allocator.free(concrete.arg_exprs);
                    call_args[0] = .{ .value = concrete.arg_exprs[0] };
                    callee = concrete.name;
                    callee_module = concrete.module_name;
                    provenance = concrete.return_provenance;
                }
            }
            out.* = .{ .call = .{
                .decl_id = maybeRegisteredDeclId(context, callee_module, null, callee, .function),
                .module_name = callee_module,
                .owner = null,
                .callee = callee,
                .args = call_args,
            } };
            try attachCheckedCallUse(context, out, target, context.function_state.active_source_decl_id, literal.token.offset);
            return makeTypedExprFromIdWithProvenance(out, target, provenance);
        }

        pub fn lowerTupleLiteral(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            literal: ast.ArrayLiteral,
            expected_type_id: ?semantic_types.TypeId,
        ) SemaError!TypedExpr {
            const expected_members: ?[]const semantic_types.TypeId = if (expected_type_id) |expected| switch (canonicalTypeNode(context, expected).*) {
                .tuple => |members| members,
                else => null,
            } else null;
            if (expected_type_id != null and expected_members == null) {
                try context.diagnostic_context.emitToken(path, literal.token, "tuple expression requires a tuple target type", .{});
                return SemaError.SemanticFailed;
            }
            if (expected_members) |members| {
                if (members.len != literal.items.len) {
                    try context.diagnostic_context.emitToken(path, literal.token, "tuple expects {d} elements, got {d}", .{ members.len, literal.items.len });
                    return SemaError.SemanticFailed;
                }
            }
            const items = try allocator.alloc(*sir.Expr, literal.items.len);
            var initialized: usize = 0;
            errdefer {
                for (items[0..initialized]) |item| item.destroy(allocator);
                allocator.free(items);
            }
            const member_types = try allocator.alloc(semantic_types.TypeId, literal.items.len);
            defer allocator.free(member_types);
            var combined_provenance = Provenance.none();
            for (literal.items, items, member_types, 0..) |item, *lowered, *member_type, index| {
                const expected = if (expected_members) |members| members[index] else null;
                const value = try lowerExprInContext(context, allocator, path, program, current_module, globals, locals, item, expected);
                lowered.* = value.expr;
                initialized += 1;
                if (expected) |target| try expectType(context, path, firstExprToken(item), target, value.type_id);
                member_type.* = expected orelse value.type_id;
                try lowerImplicitHandoff(context, path, program, locals, item, member_type.*, value.expr);
                try markCheckedNamedHandoff(context, path, program, @constCast(locals), item, value.expr, member_type.*);
                combined_provenance = Provenance.combine(combined_provenance, value.provenance);
            }
            const tuple_type = expected_type_id orelse canonicalTypeInterner(context).intern(.{ .tuple = member_types }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidTypeId => return error.SemanticFailed,
            };
            out.* = .{ .tuple_literal = .{ .type_id = tuple_type, .items = items } };
            return makeTypedExprFromIdWithProvenance(out, tuple_type, combined_provenance);
        }

        pub fn lowerArrayLiteral(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            literal: ast.ArrayLiteral,
            expected_type_id: ?semantic_types.TypeId,
        ) SemaError!TypedExpr {
            // A literal whose items are binders has no concrete element type to infer
            // the target from at the definition site. The trial lowers the items and
            // takes the first binder as the element type so the body still records the
            // method uses each item carries; the specialization that substitutes the
            // binders re-lowers the literal against its concrete types.
            if (expected_type_id == null and literal.items.len > 0) {
                var deferred_items: std.ArrayListUnmanaged(*sir.Expr) = .empty;
                defer {
                    for (deferred_items.items) |node| node.destroy(allocator);
                    deferred_items.deinit(allocator);
                }
                var element_type: ?semantic_types.TypeId = null;
                var element_shape: ?*const generic_shapes.Shape = null;
                for (literal.items) |item| {
                    const value = try lowerExpr(context, allocator, path, program, current_module, globals, locals, item, null);
                    errdefer value.expr.destroy(allocator);
                    if (element_type == null) element_type = value.type_id;
                    if (element_type.? == value.type_id) {
                        try deferred_items.append(allocator, value.expr);
                        element_shape = value.generic_shape;
                        continue;
                    }
                    if (isDefinitionSiteBinder(context, element_type.?) and isDefinitionSiteBinder(context, value.type_id)) {
                        try deferred_items.append(allocator, value.expr);
                        element_shape = try genericShapeJoinReturns(context, element_shape orelse value.generic_shape, value.generic_shape);
                        continue;
                    }
                    break;
                }
                if (deferred_items.items.len == literal.items.len and isDefinitionSiteBinder(context, element_type.?)) {
                    const dense_type = try canonicalDenseArrayTypeId(context, element_type.?);
                    out.* = .{ .dense_array_literal = .{
                        .len = deferred_items.items.len,
                        .item_type_id = element_type.?,
                        .items = try deferred_items.toOwnedSlice(allocator),
                    } };
                    var typed = makeTypedExprFromId(out, dense_type);
                    // The literal's item type stands for the first binder, so the element
                    // origins the other items carry are recorded on the lowered literal.
                    if (element_shape) |shape| typed.generic_shape = try context.generic.shapes.wrap(context.allocator, .dense, shape);
                    return typed;
                }
            }
            const array_type_id = expected_type_id orelse {
                try context.diagnostic_context.emitTokenWith(path, literal.token, .{
                    .code = .generic_inference,
                    .help = "give the literal a target type, for example `[:]i32 [1, 2, 3]`, or assign it to a typed binding before use",
                }, "cannot infer array literal type", .{});
                return SemaError.SemanticFailed;
            };
            if (type_resolution.denseStorageLiteralItemType(typeConstructionContext(context), array_type_id)) |item_type_id| {
                return try lowerBuiltinSequenceLiteralExpr(
                    context,
                    allocator,
                    path,
                    program,
                    current_module,
                    globals,
                    locals,
                    out,
                    literal.items,
                    array_type_id,
                    item_type_id,
                    null,
                    .dense_array,
                );
            }
            if (canonicalTypeNode(context, array_type_id).* == .sparse_array) {
                const item_type_id = canonicalTypeNode(context, array_type_id).sparse_array;
                const slot_type_id = try canonicalOptionalTypeId(context, item_type_id);
                var items: std.ArrayListUnmanaged(*sir.Expr) = .empty;
                var combined_provenance = Provenance.none();
                errdefer {
                    for (items.items) |item| item.destroy(allocator);
                    items.deinit(allocator);
                }

                for (literal.items) |item| {
                    const value = try lowerExprInContext(context, allocator, path, program, current_module, globals, locals, item, slot_type_id);
                    errdefer value.expr.destroy(allocator);
                    try expectType(context, path, firstExprToken(item), slot_type_id, value.type_id);
                    try rejectProjectedResourceTransferForTypedValue(context, path, program, firstExprToken(item), value, slot_type_id, "sparse literal element");
                    try lowerImplicitHandoff(context, path, program, locals, item, slot_type_id, value.expr);
                    try markCheckedNamedHandoff(context, path, program, @constCast(locals), item, value.expr, slot_type_id);
                    combined_provenance = Provenance.combine(combined_provenance, value.provenance);
                    try items.append(allocator, value.expr);
                }

                const owned_items = try items.toOwnedSlice(allocator);
                out.* = .{ .sparse_literal = .{
                    .capacity = literal.items.len,
                    .len = literal.items.len,
                    .item_type_id = item_type_id,
                    .items = owned_items,
                } };
                return makeTypedExprFromIdWithProvenance(out, array_type_id, combined_provenance);
            }
            if (canonicalTypeNode(context, array_type_id).* != .array) {
                if (try lowerSequenceFactoryLiteral(context, allocator, path, program, current_module, globals, locals, out, literal, array_type_id)) |value| return value;
                try context.diagnostic_context.emitToken(path, literal.token, "array literal requires an expected fixed array, `[:]` array, or `[;]` storage target", .{});
                return SemaError.SemanticFailed;
            }
            const array_type = canonicalTypeNode(context, array_type_id).array;
            const item_type_id = array_type.item;
            if (literal.items.len == 0) {
                if (!try typeIsDefaultInitializable(context, path, program, item_type_id)) {
                    try context.diagnostic_context.emitToken(path, literal.token, "fixed array empty construction requires a default-initializable item type", .{});
                    return SemaError.SemanticFailed;
                }
                out.* = .{ .array_default = .{
                    .len = array_type.len,
                    .item_type_id = item_type_id,
                } };
                return makeTypedExprFromId(out, array_type_id);
            }
            if (literal.items.len != array_type.len) {
                try context.diagnostic_context.emitToken(path, literal.token, "array literal expects {d} items, got {d}", .{ array_type.len, literal.items.len });
                return SemaError.SemanticFailed;
            }

            var items: std.ArrayListUnmanaged(*sir.Expr) = .empty;
            var combined_provenance = Provenance.none();
            errdefer {
                for (items.items) |item| item.destroy(allocator);
                items.deinit(allocator);
            }

            for (literal.items) |item| {
                const value = try lowerExprInContext(context, allocator, path, program, current_module, globals, locals, item, item_type_id);
                errdefer value.expr.destroy(allocator);
                try expectType(context, path, firstExprToken(item), item_type_id, value.type_id);
                try lowerImplicitHandoff(context, path, program, locals, item, item_type_id, value.expr);
                try markCheckedNamedHandoff(context, path, program, @constCast(locals), item, value.expr, item_type_id);
                combined_provenance = Provenance.combine(combined_provenance, value.provenance);
                try items.append(allocator, value.expr);
            }

            const owned_items = try items.toOwnedSlice(allocator);
            out.* = .{ .array_literal = .{
                .len = array_type.len,
                .item_type_id = item_type_id,
                .items = owned_items,
            } };
            return makeTypedExprFromIdWithProvenance(out, array_type_id, combined_provenance);
        }

        pub fn lowerSequenceRepeat(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            repeat: ast.SequenceRepeat,
            expected_type_id: ?semantic_types.TypeId,
        ) SemaError!TypedExpr {
            if (repeat.items.len == 0) {
                try context.diagnostic_context.emitToken(path, repeat.token, "sequence repeat requires at least one item", .{});
                return SemaError.SemanticFailed;
            }
            const items = try repeatedSequenceItems(context, allocator, path, repeat);
            defer allocator.free(items);
            const literal = ast.ArrayLiteral{
                .token = repeat.token,
                .items = items,
            };
            return lowerArrayLiteral(context, allocator, path, program, current_module, globals, locals, out, literal, expected_type_id);
        }

        pub fn lowerStructLiteral(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            literal: ast.StructLiteral,
            expected_type_id: ?semantic_types.TypeId,
        ) SemaError!TypedExpr {
            var resolved_type_name: ?[]const u8 = null;
            var resolved_type_id: ?semantic_types.TypeId = null;
            if (literal.type_name) |explicit_name| {
                const explicit_type = try parseType(context, path, program, current_module, .{
                    .is_ref = false,
                    .is_owned = false,
                    .is_raw = false,
                    .is_volatile_raw = false,
                    .is_optional = false,
                    .is_slice = false,
                    .array_len = null,
                    .name = explicit_name,
                    .args = literal.type_args,
                    .token = literal.type_token,
                });
                if (canonicalTypeKind(context, explicit_type) == .@"struct") {
                    resolved_type_name = canonicalNominalDeclName(context, program, explicit_type) orelse return error.SemanticFailed;
                    resolved_type_id = explicit_type;
                }
            }

            const type_name = resolved_type_name orelse literal.type_name orelse blk: {
                if (expected_type_id) |expected| {
                    if (canonicalTypeKind(context, expected) == .@"struct") break :blk canonicalNominalDeclName(context, program, expected) orelse return error.SemanticFailed;
                }
                try context.diagnostic_context.emitToken(path, literal.type_token, "cannot infer struct literal type", .{});
                return SemaError.SemanticFailed;
            };

            const layout_type_id = resolved_type_id orelse expected_type_id;
            const decl = (if (layout_type_id) |type_id|
                canonicalStructLookup(context, program, type_id)
            else
                lookupStructDecl(context, program, current_module, type_name)) orelse {
                try context.diagnostic_context.emitToken(path, literal.type_token, "unknown struct `{s}`", .{type_name});
                return SemaError.SemanticFailed;
            };
            const field_count = switch (decl.fields) {
                .ast_fields => |fields| fields.len,
                .inst_fields => |fields| fields.len,
            };
            if (literal.fields.len > field_count) {
                try context.diagnostic_context.emitToken(path, literal.type_token, "struct `{s}` expects {d} fields, got {d}", .{ type_name, field_count, literal.fields.len });
                return SemaError.SemanticFailed;
            }
            for (literal.fields, 0..) |field, index| {
                for (literal.fields[0..index]) |previous| {
                    if (std.mem.eql(u8, previous.name, field.name)) {
                        try context.diagnostic_context.emitToken(path, field.name_token, "duplicate struct field `{s}`", .{field.name});
                        return SemaError.SemanticFailed;
                    }
                }
            }

            var fields: std.ArrayListUnmanaged(sir.StructLiteralField) = .empty;
            var combined_provenance = Provenance.none();
            errdefer {
                for (fields.items) |field| field.value.destroy(allocator);
                fields.deinit(allocator);
            }

            switch (decl.fields) {
                .ast_fields => |ast_fields| for (ast_fields) |decl_field| {
                    if (!canAccessDecl(context, current_module, decl.module_name, decl_field.is_pub)) {
                        try context.diagnostic_context.emitToken(path, literal.type_token, "field `{s}` of struct `{s}` is not public", .{ decl_field.name, type_name });
                        return SemaError.SemanticFailed;
                    }
                    if (findLiteralField(literal.fields, decl_field.name) == null and decl_field.default_value == null) {
                        try context.diagnostic_context.emitToken(path, literal.type_token, "missing field `{s}` for struct `{s}`", .{ decl_field.name, type_name });
                        return SemaError.SemanticFailed;
                    }
                },
                .inst_fields => |inst_fields| for (inst_fields) |decl_field| {
                    if (!canAccessDecl(context, current_module, decl.module_name, decl_field.is_pub)) {
                        try context.diagnostic_context.emitToken(path, literal.type_token, "field `{s}` of struct `{s}` is not public", .{ decl_field.name, type_name });
                        return SemaError.SemanticFailed;
                    }
                    if (findLiteralField(literal.fields, decl_field.name) == null and decl_field.default_value == null) {
                        try context.diagnostic_context.emitToken(path, literal.type_token, "missing field `{s}` for struct `{s}`", .{ decl_field.name, type_name });
                        return SemaError.SemanticFailed;
                    }
                },
            }

            for (literal.fields) |literal_field| {
                const decl_field = lookupStructField(decl, literal_field.name) orelse {
                    try context.diagnostic_context.emitToken(path, literal_field.name_token, "struct `{s}` has no field `{s}`", .{ type_name, literal_field.name });
                    return SemaError.SemanticFailed;
                };
                const field_type = try structFieldTypeId(context, path, program, decl, decl_field);
                const value = try lowerExprInContext(context, allocator, path, program, current_module, globals, locals, literal_field.value, field_type);
                errdefer value.expr.destroy(allocator);
                try expectType(context, path, literal_field.name_token, field_type, value.type_id);
                try rejectProjectedResourceTransferForTypedValue(context, path, program, literal_field.name_token, value, field_type, "struct literal field");
                try lowerImplicitHandoff(context, path, program, locals, literal_field.value, field_type, value.expr);
                try markCheckedNamedHandoff(context, path, program, @constCast(locals), literal_field.value, value.expr, field_type);
                combined_provenance = Provenance.combine(combined_provenance, value.provenance);
                try fields.append(allocator, .{ .name = literal_field.name, .value = value.expr });
            }

            switch (decl.fields) {
                .ast_fields => |decl_fields| for (decl_fields) |decl_field| {
                    if (findLiteralField(literal.fields, decl_field.name) != null) continue;
                    const default_value = decl_field.default_value orelse continue;
                    const value = try lowerStructDefaultField(context, allocator, path, program, decl, globals, decl_field.name, default_value);
                    errdefer value.expr.destroy(allocator);
                    combined_provenance = Provenance.combine(combined_provenance, value.provenance);
                    try fields.append(allocator, .{ .name = decl_field.name, .value = value.expr });
                },
                .inst_fields => |decl_fields| for (decl_fields) |decl_field| {
                    if (findLiteralField(literal.fields, decl_field.name) != null) continue;
                    const default_value = decl_field.default_value orelse continue;
                    const value = try lowerStructDefaultField(context, allocator, path, program, decl, globals, decl_field.name, default_value);
                    errdefer value.expr.destroy(allocator);
                    combined_provenance = Provenance.combine(combined_provenance, value.provenance);
                    try fields.append(allocator, .{ .name = decl_field.name, .value = value.expr });
                },
            }

            const owned_decl_id = try registeredOrGeneratedDeclId(context, decl.module_name, null, type_name, .@"struct");
            const owned_fields = try fields.toOwnedSlice(allocator);
            out.* = .{ .struct_literal = .{
                .decl_id = owned_decl_id,
                .type_name = type_name,
                .type_module_name = decl.module_name,
                .fields = owned_fields,
            } };
            const result_type = try canonicalNominalTypeId(context, .@"struct", try registeredOrGeneratedDeclId(context, decl.module_name, null, type_name, .@"struct"), null);
            return try makeTypedExprWithProvenance(context, out, result_type, combined_provenance);
        }

        pub fn lowerFieldAccess(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            field: ast.FieldAccess,
        ) SemaError!TypedExpr {
            if (field.object.* == .name) {
                const object_name = field.object.name.text;
                if (findLocal(locals, object_name)) |local| {
                    if (local.is_failure_view) {
                        const detail: sir.FailureDetailField = if (std.mem.eql(u8, field.field, "available"))
                            .available
                        else if (std.mem.eql(u8, field.field, "origin"))
                            .origin
                        else if (std.mem.eql(u8, field.field, "origin_file"))
                            .origin_file
                        else if (std.mem.eql(u8, field.field, "site_count"))
                            .site_count
                        else if (std.mem.eql(u8, field.field, "omitted"))
                            .omitted
                        else if (std.mem.eql(u8, field.field, "message"))
                            .message
                        else {
                            try context.diagnostic_context.emitToken(path, field.field_token, "unknown failure detail `{s}`", .{field.field});
                            return SemaError.SemanticFailed;
                        };
                        out.* = .{ .failure_detail = .{
                            .binding_id = local.binding_id orelse return SemaError.SemanticFailed,
                            .field = detail,
                        } };
                        const detail_type = switch (detail) {
                            .available => try canonicalPrimitiveTypeId(context, .bool),
                            .origin => try canonicalIntegerTypeId(context, "u32"),
                            .origin_file => try canonicalPrimitiveTypeId(context, .string),
                            .site_count, .omitted => try canonicalIntegerTypeId(context, "i64"),
                            .message => try canonicalPrimitiveTypeId(context, .string),
                            .site, .site_file => unreachable,
                        };
                        return try makeTypedExprWithProvenance(context, out, detail_type, .none());
                    }
                }
                if (findImportedModulePath(program, current_module, object_name)) |module_name| {
                    if (findGlobalInModule(globals, module_name, field.field)) |global| {
                        if (!global.is_pub) {
                            try context.diagnostic_context.emitToken(path, field.field_token, "global `{s}` in module `{s}` is not public", .{ field.field, module_name });
                            return SemaError.SemanticFailed;
                        }
                        if (global.is_mutable or global.is_extern) {
                            try context.diagnostic_context.emitToken(path, field.field_token, "module-qualified value access only supports public compile-time constants", .{});
                            return SemaError.SemanticFailed;
                        }
                        out.* = .{ .global_ref = .{
                            .decl_id = global.id,
                            .module_name = module_name,
                            .name = global.name,
                        } };
                        return try makeTypedExprWithProvenance(
                            context,
                            out,
                            global.type_id,
                            try rootedBorrowProvenanceForType(context, path, program, module_name, global.type_id, .global, global.name),
                        );
                    }

                    try context.diagnostic_context.emitToken(path, field.field_token, "module namespace `{s}` cannot be used as a value; module `{s}` has no public compile-time constant `{s}`\nhelp: call public functions as `{s}.{s}(...)`, or define `pub const {s}` in module `{s}`", .{
                        object_name,
                        module_name,
                        field.field,
                        object_name,
                        field.field,
                        field.field,
                        module_name,
                    });
                    return SemaError.SemanticFailed;
                }

                if (findAccessibleStruct(context, program, current_module, object_name)) |decl| {
                    if (findGlobalMemberInModule(globals, decl.module_name, decl.name, field.field)) |global| {
                        if (!canAccessDecl(context, current_module, decl.module_name, global.is_pub)) {
                            try context.diagnostic_context.emitToken(path, field.field_token, "constant `{s}` of struct `{s}` is not public", .{ field.field, decl.name });
                            return SemaError.SemanticFailed;
                        }
                        if (global.is_mutable or global.is_extern) {
                            try context.diagnostic_context.emitToken(path, field.field_token, "struct-qualified value access only supports compile-time constants", .{});
                            return SemaError.SemanticFailed;
                        }
                        out.* = .{ .global_ref = .{
                            .decl_id = global.id,
                            .module_name = global.module_name,
                            .owner = global.owner,
                            .name = global.name,
                        } };
                        return try makeTypedExprWithProvenance(
                            context,
                            out,
                            global.type_id,
                            try rootedBorrowProvenanceForType(context, path, program, global.module_name, global.type_id, .global, global.name),
                        );
                    }
                }
            } else if (field.object.* == .field) {
                const namespace = field.object.field;
                if (namespace.object.* == .name) {
                    if (findImportedModulePath(program, current_module, namespace.object.name.text)) |module_name| {
                        if (findStructInModule(program, module_name, namespace.field)) |decl| {
                            if (!decl.is_pub) {
                                try context.diagnostic_context.emitToken(path, namespace.field_token, "struct `{s}` in module `{s}` is not public", .{ namespace.field, module_name });
                                return SemaError.SemanticFailed;
                            }
                            if (findGlobalMemberInModule(globals, module_name, decl.name, field.field)) |global| {
                                if (!global.is_pub) {
                                    try context.diagnostic_context.emitToken(path, field.field_token, "constant `{s}` of struct `{s}` is not public", .{ field.field, decl.name });
                                    return SemaError.SemanticFailed;
                                }
                                if (global.is_mutable or global.is_extern) {
                                    try context.diagnostic_context.emitToken(path, field.field_token, "struct-qualified value access only supports compile-time constants", .{});
                                    return SemaError.SemanticFailed;
                                }
                                out.* = .{ .global_ref = .{
                                    .decl_id = global.id,
                                    .module_name = global.module_name,
                                    .owner = global.owner,
                                    .name = global.name,
                                } };
                                return try makeTypedExprWithProvenance(
                                    context,
                                    out,
                                    global.type_id,
                                    try rootedBorrowProvenanceForType(context, path, program, global.module_name, global.type_id, .global, global.name),
                                );
                            }
                        }
                    }
                }
            }

            var object = try lowerExpr(context, allocator, path, program, current_module, globals, locals, field.object, null);
            errdefer object.expr.destroy(allocator);
            const object_type = canonicalUnwrapOwned(context, object.type_id);
            if (isDefinitionSiteBinder(context, object_type)) {
                return try deferConcreteKindForm(context, allocator, path, program, current_module, &object, out);
            }
            if (std.mem.eql(u8, field.field, "ptr")) {
                switch (canonicalTypeNode(context, object_type).*) {
                    .slice => |slice| {
                        out.* = .{ .slice_ptr = object.expr };
                        return makeTypedExprFromId(out, try canonicalQualifiedRawTypeId(context, slice.item, slice.is_const, false));
                    },
                    else => {},
                }
            }
            if (canonicalTypeNode(context, object_type).* == .tuple) {
                const members = canonicalTypeNode(context, object_type).tuple;
                const index = std.fmt.parseInt(usize, field.field, 10) catch {
                    try context.diagnostic_context.emitToken(path, field.field_token, "tuple position must be a decimal integer", .{});
                    return SemaError.SemanticFailed;
                };
                if (index >= members.len) {
                    try context.diagnostic_context.emitToken(path, field.field_token, "tuple position {d} is out of bounds for {d} elements", .{ index, members.len });
                    return SemaError.SemanticFailed;
                }
                const member_type = members[index];
                const member_has_storage_lifetime = try typeHasStorageLifetime(context, path, program, member_type);
                const member_may_carry_borrowed = try typeMayCarryBorrowedProvenance(context, path, program, current_module, member_type);
                out.* = .{ .tuple_field = .{
                    .object = object.expr,
                    .tuple_type_id = object_type,
                    .index = index,
                } };
                return makeTypedExprWithProvenanceAndValueSemantics(
                    context,
                    out,
                    member_type,
                    object.provenance.derived(),
                    projectedReadValueSemantics(member_has_storage_lifetime, member_may_carry_borrowed),
                );
            }
            if (canonicalTypeKind(context, object_type) == .@"struct") {
                const struct_name = canonicalNominalDeclName(context, program, object_type) orelse return error.SemanticFailed;
                const decl = canonicalStructLookup(context, program, object_type) orelse return error.SemanticFailed;
                const struct_decl_id = canonicalNominalDeclId(context, object_type) orelse
                    try registeredDeclId(context, decl.module_name, null, struct_name, .@"struct");
                const decl_field = lookupStructField(decl, field.field) orelse {
                    try context.diagnostic_context.emitToken(path, field.field_token, "struct `{s}` has no field `{s}`", .{ struct_name, field.field });
                    return SemaError.SemanticFailed;
                };
                if (!canAccessDecl(context, current_module, decl.module_name, decl_field.is_pub)) {
                    try context.diagnostic_context.emitToken(path, field.field_token, "field `{s}` of struct `{s}` is not public", .{ field.field, struct_name });
                    return SemaError.SemanticFailed;
                }

                const field_type_id = try structFieldTypeId(context, path, program, decl, decl_field);
                const field_has_storage_lifetime = try typeHasStorageLifetime(context, path, program, field_type_id);
                const field_may_carry_borrowed = try typeMayCarryBorrowedProvenance(context, path, program, current_module, field_type_id);
                out.* = if (projectedReadValueSemantics(field_has_storage_lifetime, field_may_carry_borrowed).category == .borrowed_projection)
                    .{ .borrowed_field = .{
                        .object = object.expr,
                        .struct_decl_id = struct_decl_id,
                        .struct_name = struct_name,
                        .field = field.field,
                    } }
                else
                    .{ .field = .{
                        .object = object.expr,
                        .struct_decl_id = struct_decl_id,
                        .struct_name = struct_name,
                        .field = field.field,
                    } };
                return makeTypedExprWithProvenanceAndValueSemantics(
                    context,
                    out,
                    field_type_id,
                    object.provenance.derived(),
                    projectedReadValueSemantics(field_has_storage_lifetime, field_may_carry_borrowed),
                );
            }

            if (canonicalTypeKind(context, object_type) == .@"union") {
                const union_name = canonicalNominalDeclName(context, program, object_type) orelse return error.SemanticFailed;
                const decl = canonicalUnionLookup(context, program, object_type) orelse return error.SemanticFailed;
                if (decl.layout == .c and context.function_state.unchecked_depth == 0) {
                    try context.diagnostic_context.emitToken(path, field.field_token, "reading `c union` field `{s}.{s}` requires `unchecked`", .{ union_name, field.field });
                    return SemaError.SemanticFailed;
                }
                const resolved = try typeUnionPayloadField(context, path, program, current_module, object_type, field.field, field.field_token);
                const resolved_field_has_storage_lifetime = try typeHasStorageLifetime(context, path, program, resolved.field_type_id);
                const resolved_field_may_carry_borrowed = try typeMayCarryBorrowedProvenance(context, path, program, current_module, resolved.field_type_id);
                out.* = if (projectedReadValueSemantics(resolved_field_has_storage_lifetime, resolved_field_may_carry_borrowed).category == .borrowed_projection)
                    .{ .borrowed_union_field = .{
                        .object = object.expr,
                        .union_decl_id = resolved.union_decl_id,
                        .union_name = union_name,
                        .field = field.field,
                    } }
                else
                    .{ .union_field = .{
                        .object = object.expr,
                        .union_decl_id = resolved.union_decl_id,
                        .union_name = union_name,
                        .field = field.field,
                    } };
                return makeTypedExprWithProvenanceAndValueSemantics(
                    context,
                    out,
                    resolved.field_type_id,
                    object.provenance.derived(),
                    projectedReadValueSemantics(resolved_field_has_storage_lifetime, resolved_field_may_carry_borrowed),
                );
            }

            try context.diagnostic_context.emitToken(path, field.field_token, "field access requires a struct or union value", .{});
            return SemaError.SemanticFailed;
        }

        pub fn lowerEnumCase(context: *SemaContext, path: []const u8, program: ast.Program, current_module: []const u8, out: *sir.Expr, case: ast.EnumCaseExpr) SemaError!TypedExpr {
            const decl = findEnum(context, program, current_module, case.type_name) orelse resolved: {
                if (lookup.findTypeAlias(context, program, current_module, case.type_name) != null) {
                    const alias_type = try parseCanonicalType(context, path, program, current_module, .{
                        .name = case.type_name,
                        .args = &.{},
                        .token = case.token,
                    });
                    // Resolve through the ordinary type path so aliases retain the
                    // underlying enum identity and declaration-site import scope.
                    if (canonicalTypeKind(context, alias_type) == .@"enum") {
                        const enum_id = canonicalNominalDeclId(context, alias_type) orelse return error.SemanticFailed;
                        break :resolved lookupEnumDeclById(context, program, enum_id) orelse return error.SemanticFailed;
                    }
                }
                try context.diagnostic_context.emitToken(path, case.token, "unknown enum `{s}`", .{case.type_name});
                return SemaError.SemanticFailed;
            };

            return lowerEnumCaseDecl(context, path, out, decl, case.type_name, case.case_name, case.token);
        }

        /// Lower an enum case whose enum type has already been resolved. The
        /// declaration is selected by canonical identity, not by short name.
        pub fn lowerEnumCaseForType(context: *SemaContext, path: []const u8, program: ast.Program, out: *sir.Expr, enum_type_id: semantic_types.TypeId, case_name: []const u8, token: lexer.Token) SemaError!TypedExpr {
            const enum_id = canonicalNominalDeclId(context, enum_type_id) orelse return error.SemanticFailed;
            const decl = lookupEnumDeclById(context, program, enum_id) orelse return error.SemanticFailed;
            const type_name = canonicalNominalDeclName(context, program, enum_type_id) orelse decl.name;
            return lowerEnumCaseDecl(context, path, out, decl, type_name, case_name, token);
        }

        fn lowerEnumCaseDecl(context: *SemaContext, path: []const u8, out: *sir.Expr, decl: ast.EnumDecl, type_name: []const u8, case_name: []const u8, token: lexer.Token) SemaError!TypedExpr {
            var next_value: i64 = 0;
            for (decl.cases) |decl_case| {
                const value = decl_case.value orelse next_value;
                if (std.mem.eql(u8, decl_case.name, case_name)) {
                    const owned_decl_id = try registeredDeclId(context, decl.module_name, null, decl.name, .@"enum");
                    out.* = .{ .enum_case = .{
                        .decl_id = owned_decl_id,
                        .type_name = type_name,
                        .case_name = case_name,
                        .value = value,
                    } };
                    return makeTypedExprFromId(out, try canonicalNominalTypeId(context, .@"enum", try registeredDeclId(context, decl.module_name, null, decl.name, .@"enum"), null));
                }
                next_value = value + 1;
            }

            try context.diagnostic_context.emitToken(path, token, "enum `{s}` has no case `{s}`", .{ type_name, case_name });
            return SemaError.SemanticFailed;
        }

        pub fn lowerBuiltinLenMethodCall(context: *SemaContext, out: *sir.Expr, kind: BuiltinLenKind, object_expr: *sir.Expr) SemaError!TypedExpr {
            switch (kind) {
                .string => out.* = .{ .string_len = object_expr },
                .sequence => out.* = .{ .sequence_len = object_expr },
                .sparse => out.* = .{ .sparse_len = object_expr },
                .slice => out.* = .{ .slice_len = object_expr },
            }
            return withIntrinsic(makeTypedExprFromId(out, try canonicalIntegerTypeId(context, "usize")), switch (kind) {
                .string => .string_len,
                .sequence => .sequence_len,
                .sparse => .sparse_len,
                .slice => .slice_len,
            });
        }

        pub fn lowerBuiltinClearMethodCall(context: *SemaContext, out: *sir.Expr, kind: BuiltinClearKind, object_expr: *sir.Expr) SemaError!TypedExpr {
            switch (kind) {
                .sequence => out.* = .{ .sequence_clear = object_expr },
                .sparse => out.* = .{ .sparse_clear = object_expr },
            }
            return withIntrinsic(makeTypedExprFromId(out, try canonicalPrimitiveTypeId(context, .void)), switch (kind) {
                .sequence => .sequence_clear,
                .sparse => .sparse_clear,
            });
        }

        pub fn lowerBuiltinContainsMethodCall(context: *SemaContext, out: *sir.Expr, kind: BuiltinContainsKind, object_expr: *sir.Expr, arg_expr: *sir.Expr) SemaError!TypedExpr {
            switch (kind) {
                .sparse_index => out.* = .{ .sparse_contains_index = .{
                    .object = object_expr,
                    .index = arg_expr,
                } },
            }
            return withIntrinsic(makeTypedExprFromId(out, try canonicalPrimitiveTypeId(context, .bool)), .sparse_contains_index);
        }

        pub fn lowerBuiltinPopMethodCall(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            out: *sir.Expr,
            call: ast.MethodCall,
            object: TypedExpr,
            method_builtin: TypeBuiltinPopMethod,
        ) SemaError!TypedExpr {
            if (call.args.len != 0) {
                try context.diagnostic_context.emitToken(path, call.method_token, "{s}.{s} expects no arguments", .{ method_builtin.owner_name, method_builtin.method_name });
                return SemaError.SemanticFailed;
            }
            try prepareMutableContainerMethod(context, path, program, current_module, globals, locals, call.object, object.type_id, method_builtin.receiver_name, call.method_token, method_builtin.mutation_action);
            out.* = .{ .sequence_pop = object.expr };
            const item_type = method_builtin.item_type_id;
            return withIntrinsic(
                try makeTypedExprWithProvenance(context, out, item_type, try propagatedProvenanceForType(context, path, program, current_module, item_type, object.provenance.derived())),
                .sequence_pop,
            );
        }

        pub fn lowerBorrowedGlobalFieldReceiver(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            root_name: ast.Name,
            global: GlobalBinding,
            reversed_steps: []const TakeAstStep,
        ) SemaError!*sir.Expr {
            var current_type = canonicalUnwrapOwned(context, global.type_id);
            var current_expr = try allocator.create(sir.Expr);
            errdefer current_expr.destroy(allocator);
            current_expr.* = .{ .ref_global = .{
                .decl_id = global.id,
                .module_name = global.module_name,
                .owner = global.owner,
                .name = global.name,
            } };

            var i: usize = reversed_steps.len;
            while (i > 0) {
                i -= 1;
                const step = reversed_steps[i];
                switch (step) {
                    .field => |field| {
                        const resolved = try typeStructField(context, path, program, current_module, current_type, field.field, field.field_token);
                        if (resolved.decl.layout == .@"packed") {
                            try context.diagnostic_context.emitToken(path, field.field_token, "cannot create alias to packed field `{s}` in safe code", .{field.field});
                            return SemaError.SemanticFailed;
                        }
                        const next_expr = try allocator.create(sir.Expr);
                        next_expr.* = .{ .ref_field_expr = .{
                            .object = current_expr,
                            .struct_decl_id = resolved.struct_decl_id,
                            .struct_name = resolved.struct_name,
                            .field = field.field,
                        } };
                        current_expr = next_expr;
                        current_type = resolved.field_type_id;
                    },
                    .index => {
                        try context.diagnostic_context.emitToken(path, root_name.token, "global receiver aliases require a field projection", .{});
                        return SemaError.SemanticFailed;
                    },
                }
            }

            return current_expr;
        }

        pub fn lowerAddressOfGlobalFieldAlias(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            out: *sir.Expr,
            source_expr: *ast.Expr,
            root_name: ast.Name,
            global: GlobalBinding,
            reversed_steps: []const TakeAstStep,
        ) SemaError!TypedExpr {
            try rejectIsolatedMutableGlobalAccess(context, path, root_name.token, global, "borrow");
            const place = resolvePlace(context, program, current_module, &.{global}, &.{}, source_expr) orelse
                return SemaError.SemanticFailed;

            var current_type = canonicalUnwrapOwned(context, global.type_id);
            var current_expr = try allocator.create(sir.Expr);
            errdefer current_expr.destroy(allocator);
            current_expr.* = .{ .ref_global = .{
                .decl_id = global.id,
                .module_name = global.module_name,
                .owner = global.owner,
                .name = global.name,
            } };
            if (reversed_steps.len != 0) {
                var root_typed = try makeTypedExprWithProvenance(
                    context,
                    current_expr,
                    try canonicalRefTypeIdForAccess(context, current_type, place.access),
                    Provenance.fromNormalizedBorrowRoots(place.roots),
                );
                try finalizeAndRecordExprSemantics(context, path, program, current_module, &root_typed);
            }
            var i: usize = reversed_steps.len;
            while (i > 0) {
                i -= 1;
                switch (reversed_steps[i]) {
                    .field => |field| {
                        const resolved = try typeStructField(context, path, program, current_module, current_type, field.field, field.field_token);
                        if (resolved.decl.layout == .@"packed") {
                            try context.diagnostic_context.emitToken(path, field.field_token, "cannot create alias to packed field `{s}` in safe code", .{field.field});
                            return SemaError.SemanticFailed;
                        }
                        const next = try allocator.create(sir.Expr);
                        next.* = .{ .ref_field_expr = .{
                            .object = current_expr,
                            .struct_decl_id = resolved.struct_decl_id,
                            .struct_name = resolved.struct_name,
                            .field = field.field,
                        } };
                        current_expr = next;
                        current_type = resolved.field_type_id;
                        if (i != 0) {
                            var projected = try makeTypedExprWithProvenance(
                                context,
                                current_expr,
                                try canonicalRefTypeIdForAccess(context, current_type, place.access),
                                Provenance.fromNormalizedBorrowRoots(place.roots),
                            );
                            try finalizeAndRecordExprSemantics(context, path, program, current_module, &projected);
                        }
                    },
                    .index => {
                        try context.diagnostic_context.emitToken(path, root_name.token, "global aliases currently require a field-only projection", .{});
                        return SemaError.SemanticFailed;
                    },
                }
            }

            out.* = current_expr.*;
            allocator.destroy(current_expr);
            return try makeTypedExprWithProvenance(
                context,
                out,
                try canonicalRefTypeIdForAccess(context, current_type, place.access),
                Provenance.fromNormalizedBorrowRoots(place.roots),
            );
        }

        /// Record a join the lowering computed for a placeholder type it interned.
        pub fn recordDeferredShape(context: *SemaContext, type_id: semantic_types.TypeId, shape: *const generic_shapes.Shape) SemaError!void {
            for (context.generic.deferred_shapes.items) |record| {
                if (record.type_id == type_id) return;
            }
            try context.generic.deferred_shapes.append(context.allocator, .{ .type_id = type_id, .shape = shape });
        }
        /// The definition-site shape a lowered expression stands for. The canonical
        /// type already names every binder and wrapper the body lowered the expression
        /// into, so the shape is read off the type instead of a second walk of the
        /// syntax. A canonical type cannot name the set of binders one lowered value
        /// can stand for, so the joins lowering recorded for its placeholder types are
        /// read back here.
        pub fn shapeFromCanonicalType(
            context: *SemaContext,
            type_id: semantic_types.TypeId,
            projected: bool,
        ) SemaError!*const generic_shapes.Shape {
            const store = &context.generic.shapes;
            const node = canonicalTypeNode(context, type_id);
            return switch (node.*) {
                .primitive, .inferred_integer, .inferred_float, .integer, .float => &generic_shapes.known,
                .generic_parameter => |parameter| blk: {
                    if (parameter.scope == placeholder_generic_scope) {
                        for (context.generic.deferred_shapes.items) |record| {
                            if (record.type_id == type_id) break :blk record.shape;
                        }
                        break :blk &generic_shapes.unknown;
                    }
                    const origin = canonicalReceiverOrigin(context, type_id, projected) orelse break :blk &generic_shapes.unknown;
                    break :blk store.add(context.allocator, .{ .parameter = origin });
                },
                .ref_ => |reference| try store.wrap(context.allocator, .ref_, try shapeFromCanonicalType(context, reference.target, projected)),
                .owned => |inner| try store.wrap(context.allocator, .owned, try shapeFromCanonicalType(context, inner, projected)),
                .raw => |reference| try store.wrap(context.allocator, .raw, try shapeFromCanonicalType(context, reference.target, projected)),
                .optional => |inner| try store.wrap(context.allocator, .optional, try shapeFromCanonicalType(context, inner, projected)),
                .dense_array => |inner| try store.wrap(context.allocator, .dense, try shapeFromCanonicalType(context, inner, projected)),
                .sparse_array => |inner| try store.wrap(context.allocator, .sparse, try shapeFromCanonicalType(context, inner, projected)),
                .array => |array| try store.wrap(context.allocator, .array, try shapeFromCanonicalType(context, array.item, projected)),
                .tuple => &generic_shapes.unknown,
                .slice => |slice| try store.wrap(context.allocator, .slice, try shapeFromCanonicalType(context, slice.item, projected)),
                .result => |result| try store.add(context.allocator, .{ .result = .{
                    .ok = try shapeFromCanonicalType(context, result.ok, projected),
                    .err = try shapeFromCanonicalType(context, result.err, projected),
                } }),
                .error_union => &generic_shapes.known,
                .nominal => |nominal| blk: {
                    if (nominal.underlying) |inner| break :blk try shapeFromCanonicalType(context, inner, projected);
                    break :blk store.add(context.allocator, .{ .nominal = .{ .declaration = nominal.decl_id, .args = &.{} } });
                },
                .generic_instance => |instance| blk: {
                    const args = try store.allocator(context.allocator).alloc(*const generic_shapes.Shape, instance.args.len);
                    for (instance.args, args) |argument, *shape| shape.* = switch (argument) {
                        .type => |argument_type| try shapeFromCanonicalType(context, argument_type, projected),
                        .const_usize => &generic_shapes.known,
                    };
                    break :blk store.add(context.allocator, .{ .nominal = .{ .declaration = instance.base_decl_id, .args = args } });
                },
                .callable => |callable| blk: {
                    const params = try store.allocator(context.allocator).alloc(*const generic_shapes.Shape, callable.params.len);
                    for (callable.params, params) |parameter, *shape| shape.* = try shapeFromCanonicalType(context, parameter, projected);
                    break :blk try store.add(context.allocator, .{ .callable = .{ .params = params, .result = try shapeFromCanonicalType(context, callable.return_type, projected) } });
                },
            };
        }
        pub fn shapeProjectionLayer(
            context: *SemaContext,
            source: *const generic_shapes.Shape,
            projection: ShapeProjection,
        ) SemaError!*const generic_shapes.Shape {
            const store = &context.generic.shapes;
            const value = source.unborrow();
            if (value.* == .alternatives) {
                return try genericShapeJoinReturns(context, try shapeProjectionLayer(context, value.alternatives.left, projection), try shapeProjectionLayer(context, value.alternatives.right, projection));
            }
            if (value.* == .wrapper) {
                const kind = value.wrapper.kind;
                const child = value.wrapper.child;
                if (projection == .iter_item) {
                    if (kind == .array or kind == .slice or kind == .dense or kind == .sparse) return child;
                } else if (projection == .index) {
                    if (kind == .array or kind == .slice or kind == .dense or kind == .raw) return child;
                    if (kind == .optional) return child;
                    if (kind == .sparse) return try store.wrap(context.allocator, .optional, child);
                } else if (projection == .slice) {
                    if (kind == .array or kind == .slice or kind == .dense or kind == .sparse or kind == .optional)
                        return try store.wrap(context.allocator, .slice, child);
                } else if (projection == .payload) {
                    if (kind == .optional) return child;
                }
            }
            if (value.* == .result and projection == .payload) return value.result.ok;
            return try store.project(context.allocator, value);
        }
        /// The shape a lowered projection of a value stands for. The lowering already
        /// settled the projected layer's canonical type for every container and hook it
        /// could type; a receiver whose layer the definition site cannot name -- a join
        /// of two binders, an inferred callback result -- keeps the shape the body
        /// recorded for it, so the origins that join reaches stay visible.
        pub fn loweredProjectionShape(
            context: *SemaContext,
            source: *const generic_shapes.Shape,
            projected_type: ?semantic_types.TypeId,
            projection: ShapeProjection,
        ) SemaError!*const generic_shapes.Shape {
            const value = source.unborrow();
            if (value.* != .alternatives and value.* != .wrapper and value.* != .result) {
                if (projected_type) |type_id| return try shapeFromCanonicalType(context, type_id, false);
            }
            return try shapeProjectionLayer(context, source, projection);
        }
        pub fn loweredIndexElementType(context: *SemaContext, path: []const u8, program: ast.Program, module_name: []const u8, type_id: semantic_types.TypeId) SemaError!?semantic_types.TypeId {
            if (try type_resolution.typeIndexAccessRole(typeConstructionContext(context), type_id)) |role| return role.value_type_id;
            if (isDefinitionSiteBinder(context, type_id)) return null;
            return try indexHookReturnTypeForType(context, path, program, module_name, type_id);
        }
        pub fn isDeclaredGenericStorageOperation(origin: GenericReceiverOrigin, method: []const u8) bool {
            // `^T.ptr/leak` belong to the explicitly declared ownership wrapper, not
            // to behavior discovered on T after substitution.
            return origin.owned_wrapper and intrinsics.resolveMethod(.owned, method) != null;
        }
        /// The binder a lowered receiver still stands for at its declaration's
        /// definition site. The canonical type is the authority: a receiver carries
        /// generic authority only when its canonical root is a binder, possibly through
        /// the ref and owned wrappers the lowering keeps. `projected` marks a value the
        /// body derived from the binder with a form that needs the concrete kind -- a
        /// field, an index, a dereference, a call, a loop item, or a case payload --
        /// which the definition site defers and each specialization re-lowers.
        pub fn canonicalReceiverOrigin(
            context: *SemaContext,
            type_id: semantic_types.TypeId,
            projected: bool,
        ) ?GenericReceiverOrigin {
            const scopes = context.generic_scopes orelse return null;
            var current = type_id;
            var owned_wrapper = false;
            while (true) {
                const node = canonicalTypeNode(context, current);
                switch (node.*) {
                    .ref_ => current = node.ref_.target,
                    .owned => {
                        owned_wrapper = true;
                        current = node.owned;
                    },
                    .generic_parameter => |reference| {
                        const id: identity.GenericParamId = .{ .scope = reference.scope, .ordinal = reference.ordinal };
                        const parameter = scopes.paramDecl(id) orelse return null;
                        const module_name = scopes.paramModule(id) orelse return null;
                        return GenericReceiverOrigin{
                            .parameter = parameter,
                            .module_name = module_name,
                            .owned_wrapper = owned_wrapper,
                            .projected = projected,
                        };
                    },
                    else => return null,
                }
            }
        }
        pub fn receiverOriginFromType(context: *SemaContext, type_id: semantic_types.TypeId) ?GenericReceiverOrigin {
            return canonicalReceiverOrigin(context, type_id, false);
        }
        /// The origin of a value the body projected out of a binder.
        pub fn projectedOrigin(origin: ?GenericReceiverOrigin) ?GenericReceiverOrigin {
            const value = origin orelse return null;
            return .{
                .parameter = value.parameter,
                .module_name = value.module_name,
                .owned_wrapper = value.owned_wrapper,
                .projected = true,
            };
        }
        /// Emits a generic method admission diagnostic and records it for the
        /// definition-site attempt that is about to stop lowering. The first failure
        /// recorded in an attempt is the one replayed.
        pub fn recordGenericAdmission(
            context: *SemaContext,
            path: []const u8,
            token: lexer.Token,
            details: diagnostics.DiagnosticDetails,
            comptime fmt: []const u8,
            args: anytype,
        ) SemaError!void {
            return generics.recordAdmission(SemaContext, context, path, token, details, fmt, args);
        }
        pub fn genericShapeJoinReturns(context: *SemaContext, left: *const generic_shapes.Shape, right: *const generic_shapes.Shape) SemaError!*const generic_shapes.Shape {
            if (left == right) return left;
            const a = left.receiver();
            const b = right.receiver();
            if (a != null and b != null and std.mem.eql(u8, a.?.module_name, b.?.module_name) and
                a.?.parameter.name_token.offset == b.?.parameter.name_token.offset and
                std.mem.eql(u8, a.?.parameter.name, b.?.parameter.name) and
                a.?.projected == b.?.projected and a.?.owned_wrapper == b.?.owned_wrapper)
                return left;
            return context.generic.shapes.add(context.allocator, .{ .alternatives = .{ .left = left, .right = right } });
        }
        pub fn collectGenericShapeOrigins(allocator: std.mem.Allocator, shape: *const generic_shapes.Shape, origins: *std.ArrayListUnmanaged(GenericReceiverOrigin)) SemaError!void {
            switch (shape.*) {
                .alternatives => |alternatives| {
                    try collectGenericShapeOrigins(allocator, alternatives.left, origins);
                    try collectGenericShapeOrigins(allocator, alternatives.right, origins);
                },
                .wrapper => |wrapper| {
                    if (wrapper.kind != .ref_ and wrapper.kind != .owned) return;
                    const start = origins.items.len;
                    try collectGenericShapeOrigins(allocator, wrapper.child, origins);
                    if (wrapper.kind == .owned) for (origins.items[start..]) |*origin| {
                        origin.owned_wrapper = true;
                    };
                },
                else => if (shape.receiver()) |origin| try origins.append(allocator, origin),
            }
        }
        pub fn hasGenericReceiverOrigin(shape: *const generic_shapes.Shape) bool {
            return switch (shape.*) {
                .alternatives => |items| hasGenericReceiverOrigin(items.left) or hasGenericReceiverOrigin(items.right),
                .wrapper => |wrapper| (wrapper.kind == .ref_ or wrapper.kind == .owned) and hasGenericReceiverOrigin(wrapper.child),
                else => shape.receiver() != null,
            };
        }
        /// The binder origins a lowered receiver stands for. The lowered canonical type
        /// names the binder directly; the definition-site form adds the projection the
        /// type cannot name (a binder consumed as a container, callable, or pointer).
        /// Forms the lowering cannot type at all, such as an inferred callback result or
        /// a joined branch, still carry the origins the walk derived.
        pub fn receiverOrigins(
            allocator: std.mem.Allocator,
            receiver: TypedExpr,
            origins: *std.ArrayListUnmanaged(GenericReceiverOrigin),
        ) SemaError!void {
            var joined: std.ArrayListUnmanaged(GenericReceiverOrigin) = .empty;
            defer joined.deinit(allocator);
            try collectGenericShapeOrigins(allocator, receiver.generic_shape, &joined);
            // A receiver the body joined from two binders stands for every binder the
            // join can reach; the lowered origin names only the one it was written from.
            if (joined.items.len > 1) {
                try origins.appendSlice(allocator, joined.items);
                return;
            }
            if (receiver.generic_origin) |origin| {
                if (receiver.generic_shape.receiver()) |shape_origin| {
                    if (shape_origin.projected and !origin.projected) {
                        try origins.append(allocator, projectedOrigin(origin).?);
                        return;
                    }
                }
                try origins.append(allocator, origin);
                return;
            }
            try origins.appendSlice(allocator, joined.items);
        }
        pub fn declaredGenericMethodForOrigins(context: *SemaContext, path: []const u8, program: ast.Program, origins: []const GenericReceiverOrigin, call: ast.MethodCall, qualified: ?identity.DeclId) SemaError!?identity.DeclId {
            var selected = qualified;
            for (origins) |origin| {
                if (qualified == null and isDeclaredGenericStorageOperation(origin, call.method)) continue;
                const protocol = try declaredGenericMethodProtocol(context, path, program, origin, call, qualified);
                if (selected != null and selected.? != protocol) {
                    try context.diagnostic_context.emitToken(path, call.method_token, "generic method `{s}` has incompatible declared protocols across return paths", .{call.method});
                    return error.SemanticFailed;
                }
                selected = protocol;
            }
            return selected;
        }
        pub fn declaredGenericMethodProtocol(context: *SemaContext, path: []const u8, program: ast.Program, origin: GenericReceiverOrigin, call: ast.MethodCall, qualified: ?identity.DeclId) SemaError!identity.DeclId {
            var selected: ?identity.DeclId = null;
            const parameter = origin.parameter;
            if (origin.projected) {
                try recordGenericAdmission(context, path, call.method_token, .{
                    .code = .generic_constraint,
                    .help = "declare the projected type as an explicit protocol-constrained parameter, or pass the behavior as a function",
                }, "generic projection derived from `{s}` requires a declared protocol for method `{s}`", .{ parameter.name, call.method });
                return error.SemanticFailed;
            }
            const constraints = [_]?ast.TypeName{parameter.constraint};
            for (constraints) |maybe_constraint| {
                if (maybe_constraint) |constraint| {
                    const protocol = try protocols.resolveProtocolConstraint(protocols.contextFromSession(SemaContext, context), path, program, origin.module_name, constraint);
                    for (protocol.decl.methods) |method| {
                        if (!std.mem.eql(u8, method.name, call.method) or (qualified != null and qualified.? != protocol.id)) continue;
                        selected = protocol.id;
                    }
                }
            }
            for (parameter.extra_constraints) |constraint| {
                const protocol = try protocols.resolveProtocolConstraint(protocols.contextFromSession(SemaContext, context), path, program, origin.module_name, constraint);
                for (protocol.decl.methods) |method| {
                    if (!std.mem.eql(u8, method.name, call.method) or (qualified != null and qualified.? != protocol.id)) continue;
                    if (selected != null and selected.? != protocol.id) {
                        try recordGenericAdmission(context, path, call.method_token, .{}, "generic method `{s}` is ambiguous between declared protocols; qualify the protocol call", .{call.method});
                        return error.SemanticFailed;
                    }
                    selected = protocol.id;
                }
            }
            if (selected) |protocol| return protocol;
            const labels = [_]diagnostics.Label{.{ .span = declarationSpan(program, path, origin.module_name, parameter.name_token), .message = "generic parameter declared here" }};
            try recordGenericAdmission(context, path, call.method_token, .{
                .code = .generic_constraint,
                .labels = &labels,
                .help = "declare a protocol bound exposing this method, or pass the behavior as a function",
            }, "generic parameter `{s}` requires a declared protocol for method `{s}`", .{ parameter.name, call.method });
            return error.SemanticFailed;
        }
        pub fn appendOwnedLowered(allocator: std.mem.Allocator, list: anytype, value: anytype) SemaError!void {
            list.append(allocator, value) catch |err| {
                if (comptime @TypeOf(value) == TypedExpr) value.expr.destroy(allocator) else value.deinit(allocator);
                return err;
            };
        }
        pub fn registeredOrGeneratedDeclId(
            context: *SemaContext,
            module_name: []const u8,
            owner: ?[]const u8,
            name: []const u8,
            kind: identity.DeclKind,
        ) SemaError!identity.DeclId {
            return declaration_index.findOrRegisterGenerated(if (context.declarations.registry) |*registry| registry else null, module_name, owner, name, kind);
        }
        pub fn lowerInstantiatedStruct(context: *SemaContext, decl: InstantiatedStructDecl) SemaError!sir.StructDecl {
            const allocator = context.allocator;
            var fields: std.ArrayListUnmanaged(sir.FieldDecl) = .empty;
            errdefer fields.deinit(allocator);

            for (decl.fields) |field| {
                try fields.append(allocator, .{
                    .name = field.name,
                    .type_id = field.type_id,
                });
            }

            return .{
                .decl_id = decl.id orelse return error.SemanticFailed,
                .module_name = decl.module_name,
                .name = decl.name,
                .layout = switch (decl.layout) {
                    .normal => .normal,
                    .c => .c,
                    .@"packed" => .@"packed",
                },
                .is_shared_value = decl.is_shared_value,
                .shared_runtime = sharedRuntimeForContract(decl.module_name, decl.base_name),
                .drop_runtime = dropRuntimeForContract(decl.module_name, decl.base_name),
                .fields = try fields.toOwnedSlice(allocator),
            };
        }
        pub fn lookupStructDecl(context: *SemaContext, program: ast.Program, requester_module: []const u8, name: []const u8) ?StructLookup {
            if (findStruct(context, program, requester_module, name)) |decl| {
                return .{
                    .module_name = decl.module_name,
                    .layout = decl.layout,
                    .is_shared_value = decl.is_shared_value,
                    .is_owned_value = decl.is_owned_value,
                    .is_concurrency_shareable = decl.is_concurrency_shareable,
                    .fields = .{ .ast_fields = decl.fields },
                };
            }
            if (findStructAny(program, name)) |decl| {
                return .{
                    .module_name = decl.module_name,
                    .layout = decl.layout,
                    .is_shared_value = decl.is_shared_value,
                    .is_owned_value = decl.is_owned_value,
                    .is_concurrency_shareable = decl.is_concurrency_shareable,
                    .fields = .{ .ast_fields = decl.fields },
                };
            }
            if (findInstantiatedStruct(context, name)) |decl| {
                return .{
                    .module_name = decl.module_name,
                    .layout = decl.layout,
                    .is_shared_value = decl.is_shared_value,
                    .is_owned_value = decl.is_owned_value,
                    .is_concurrency_shareable = decl.is_concurrency_shareable,
                    .fields = .{ .inst_fields = decl.fields },
                };
            }
            return null;
        }
        pub fn lookupUnionDeclForType(context: *SemaContext, program: ast.Program, type_id: semantic_types.TypeId) ?ast.UnionDecl {
            const decl_id = canonicalNominalDeclId(context, type_id) orelse return null;
            return lookupUnionDeclById(context, program, decl_id);
        }
        pub fn functionTypeCallingConvention(context: *SemaContext, type_id: semantic_types.TypeId) ast.CallingConvention {
            return switch (canonicalTypeNode(context, type_id).*) {
                .callable => |callable| switch (callable.calling_convention) {
                    .cyna => .cyna,
                    .c => .c,
                },
                else => .cyna,
            };
        }
        pub fn checkedCaptureOrigin(context: *SemaContext, expr: *const sir.Expr) ?sir.CheckedCaptureOrigin {
            const metadata = semanticExprMetadata(context, expr) orelse return null;
            if (metadata.checkedPlacePath()) |place| return .{ .place = place };
            if (metadata.temporary_id) |temporary_id| return .{ .temporary = temporary_id };
            return null;
        }
        pub fn checkedCapturePath(origin: ?sir.CheckedCaptureOrigin, active_case: ?sir.CheckedPayloadCase) ?sir.CheckedCapturePath {
            return if (active_case) |case| .{ .source = origin, .active_case = case } else null;
        }
        pub fn resolveNumericBinaryType(
            context: *SemaContext,
            path: []const u8,
            left_token: lexer.Token,
            right_token: lexer.Token,
            left: semantic_types.TypeId,
            right: semantic_types.TypeId,
        ) SemaError!semantic_types.TypeId {
            try type_resolution.expectArithmeticLike(canonical.displayContext(context), &context.diagnostic_context, path, left_token, left);
            try type_resolution.expectArithmeticLike(canonical.displayContext(context), &context.diagnostic_context, path, right_token, right);
            if (canonicalTypeKind(context, left) == .float and canonicalTypeKind(context, right) == .int) return left;
            if (canonicalTypeKind(context, left) == .int and canonicalTypeKind(context, right) == .float) return right;
            if (type_resolution.intTypesCompatible(canonicalTypeNode(context, left).*, canonicalTypeNode(context, right).*)) return left;
            try expectType(context, path, right_token, left, right);
            return left;
        }
        /// A callable whose return type the definition site interned as a placeholder:
        /// its own lowered returns settle what it returns, so the body decides whether
        /// the result is still a join of binders.
        pub fn returnTypeIsDeferredPlaceholder(context: *SemaContext, type_id: semantic_types.TypeId) bool {
            const node = canonicalTypeNode(context, type_id);
            return node.* == .generic_parameter and node.generic_parameter.scope == placeholder_generic_scope;
        }
        /// Whether a lowered shape still stands for a generic binder rather than a
        /// settled concrete type, i.e. it wraps or joins a binder anywhere.
        pub fn shapeIsUnsettled(shape: *const generic_shapes.Shape) bool {
            switch (shape.*) {
                .parameter, .projection => return true,
                .alternatives => |items| return shapeIsUnsettled(items.left) or shapeIsUnsettled(items.right),
                .wrapper => |wrapper| return shapeIsUnsettled(wrapper.child),
                .result => |result| return shapeIsUnsettled(result.ok) or shapeIsUnsettled(result.err),
                .callable => |callable| {
                    for (callable.params) |param| if (shapeIsUnsettled(param)) return true;
                    return shapeIsUnsettled(callable.result);
                },
                .nominal => |nominal| {
                    for (nominal.args) |arg| if (shapeIsUnsettled(arg)) return true;
                    return false;
                },
                else => return false,
            }
        }
        /// A function expression written without a return type inside a generic
        /// definition body returns values whose concrete type is still a binder. The
        /// trial body types such a callable with an unknown concrete type: the return
        /// checks the trial body makes are deferred, and every specialization re-lowers
        /// the lambda with the substituted concrete return type.
        pub fn definitionSiteUnknownReturnType(context: *SemaContext, ordinal: u32) SemaError!semantic_types.TypeId {
            return try internCanonicalNode(&context.canonical.types.?, .{ .generic_parameter = .{
                .scope = @fromBackingInt(@intCast(std.math.maxInt(u32))),
                .ordinal = ordinal,
                .name = "inferred",
            } });
        }
        pub fn inferExplicitFunctionExprType(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            function_expr: ast.FunctionExpr,
        ) SemaError!semantic_types.TypeId {
            const params = try allocator.alloc(semantic_types.TypeId, function_expr.params.len);
            defer allocator.free(params);
            for (function_expr.params, 0..) |param, i| {
                const type_name = param.type_name orelse {
                    try context.diagnostic_context.emitToken(path, param.name_token, "function expression parameter `{s}` needs a type when no expected function type is available", .{param.name});
                    return SemaError.SemanticFailed;
                };
                params[i] = try parseCanonicalType(context, path, program, current_module, type_name);
            }
            const return_type = if (function_expr.return_type) |type_name|
                try parseCanonicalType(context, path, program, current_module, type_name)
            else
                try definitionSiteUnknownReturnType(context, @intCast(context.anonymous_function_counter + 1));
            const interner = if (context.canonical.types) |*value| value else return error.SemanticFailed;
            return internCanonicalNode(interner, .{ .callable = .{
                .kind = .function,
                .calling_convention = if (function_expr.calling_convention == .c) .c else .cyna,
                .params = params,
                .return_type = return_type,
            } });
        }
        pub fn synthesizeArrowCallableAdapter(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            module_name: []const u8,
            target: ast.Function,
            function_type_id: semantic_types.TypeId,
            debug_token: lexer.Token,
        ) SemaError![]const u8 {
            const function_type = canonicalTypeNode(context, function_type_id).callable;
            const return_type_id = function_type.return_type;
            const name = try std.fmt.allocPrint(allocator, "{s}{d}", .{ generated_names.arrow_adapter_prefix, context.anonymous_function_counter });
            context.anonymous_function_counter += 1;
            try context.output.generated_strings.append(allocator, name);

            var params = try allocator.alloc(sir.Param, function_type.params.len + 1);
            errdefer allocator.free(params);
            params[0] = .{
                .name = generated_names.closure_environment_local,
                .binding_id = try nextBindingId(context),
                .type_id = try canonicalRawTypeId(context, try canonicalIntegerTypeId(context, "u8"), false),
            };

            var args = try allocator.alloc(sir.CallArg, function_type.params.len);
            var args_owned_by_call = false;
            errdefer {
                if (!args_owned_by_call) {
                    for (args) |arg| arg.deinit(allocator);
                    allocator.free(args);
                }
            }
            for (function_type.params, 0..) |param_type_id, i| {
                const param_name = try std.fmt.allocPrint(allocator, "{s}{d}", .{ generated_names.anonymous_argument_prefix, i });
                try context.output.generated_strings.append(allocator, param_name);
                params[i + 1] = .{
                    .name = param_name,
                    .binding_id = try nextBindingId(context),
                    .type_id = param_type_id,
                };
                const arg_expr = try allocator.create(sir.Expr);
                arg_expr.* = .{ .local = param_name };
                var arg_typed = makeTypedExprFromId(arg_expr, param_type_id);
                try finalizeAndRecordExprSemantics(context, path, program, module_name, &arg_typed);
                try recordGeneratedBindingRoot(context, arg_expr, params[i + 1].binding_id.?, false);
                args[i] = .{ .value = arg_expr };
            }

            const call_expr = try allocator.create(sir.Expr);
            errdefer call_expr.destroy(allocator);
            call_expr.* = .{ .call = .{
                .intrinsic_id = intrinsics.resolveDeclaration(target.module_name, target.owner, target.name),
                .decl_id = maybeRegisteredDeclId(context, target.module_name, target.owner, target.name, .function),
                .module_name = target.module_name,
                .owner = target.owner,
                .callee = target.name,
                .args = args,
            } };
            try attachCheckedCallUse(context, call_expr, return_type_id, context.function_state.active_source_decl_id, debug_token.offset);
            var call_typed = makeTypedExprFromId(call_expr, return_type_id);
            try finalizeAndRecordExprSemantics(context, path, program, module_name, &call_typed);
            if (!canonicalTypeIsVoidLike(context, return_type_id)) try recordExprSink(context, call_expr, .@"return");
            args_owned_by_call = true;

            const body = try allocator.alloc(sir.Stmt, 1);
            errdefer allocator.free(body);
            body[0] = if (canonicalTypeIsVoidLike(context, return_type_id))
                .{ .expr = call_expr }
            else
                .{ .@"return" = call_expr };

            const decl_id = (try registerGeneratedDecl(context, module_name, null, name, .function)) orelse
                return error.SemanticFailed;
            try context.generic.instantiated_functions.append(allocator, .{
                .decl_id = decl_id,
                .module_name = module_name,
                .owner = null,
                .name = name,
                .abi_name = null,
                .is_extern = false,
                .is_export = false,
                .calling_convention = .cyna,
                .params = params,
                .return_type_id = return_type_id,
                .debug_token = debug_token,
                .body = body,
            });

            return name;
        }

        pub fn synthesizeCAbiCallableAdapter(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            module_name: []const u8,
            target: ast.Function,
            function_type_id: semantic_types.TypeId,
            debug_token: lexer.Token,
        ) SemaError![]const u8 {
            const function_type = canonicalTypeNode(context, function_type_id).callable;
            const return_type_id = function_type.return_type;
            const name = try std.fmt.allocPrint(allocator, "{s}{d}", .{
                generated_names.c_abi_adapter_prefix,
                context.anonymous_function_counter,
            });
            context.anonymous_function_counter += 1;
            try context.output.generated_strings.append(allocator, name);

            const params = try allocator.alloc(sir.Param, function_type.params.len);
            errdefer allocator.free(params);

            const args = try allocator.alloc(sir.CallArg, function_type.params.len);
            var args_owned_by_call = false;
            errdefer {
                if (!args_owned_by_call) {
                    for (args) |arg| arg.deinit(allocator);
                    allocator.free(args);
                }
            }
            for (function_type.params, 0..) |param_type_id, i| {
                const param_name = try std.fmt.allocPrint(allocator, "{s}{d}", .{
                    generated_names.anonymous_argument_prefix,
                    i,
                });
                try context.output.generated_strings.append(allocator, param_name);
                params[i] = .{
                    .name = param_name,
                    .binding_id = try nextBindingId(context),
                    .type_id = param_type_id,
                };
                const arg_expr = try allocator.create(sir.Expr);
                arg_expr.* = .{ .local = param_name };
                var arg_typed = makeTypedExprFromId(arg_expr, param_type_id);
                try finalizeAndRecordExprSemantics(
                    context,
                    path,
                    program,
                    module_name,
                    &arg_typed,
                );
                try recordGeneratedBindingRoot(
                    context,
                    arg_expr,
                    params[i].binding_id.?,
                    false,
                );
                args[i] = .{ .value = arg_expr };
            }

            const call_expr = try allocator.create(sir.Expr);
            errdefer call_expr.destroy(allocator);
            call_expr.* = .{ .call = .{
                .intrinsic_id = intrinsics.resolveDeclaration(
                    target.module_name,
                    target.owner,
                    target.name,
                ),
                .decl_id = maybeRegisteredDeclId(
                    context,
                    target.module_name,
                    target.owner,
                    target.name,
                    .function,
                ),
                .module_name = target.module_name,
                .owner = target.owner,
                .callee = target.name,
                .args = args,
            } };
            try attachCheckedCallUse(
                context,
                call_expr,
                return_type_id,
                context.function_state.active_source_decl_id,
                debug_token.offset,
            );
            var call_typed = makeTypedExprFromId(call_expr, return_type_id);
            try finalizeAndRecordExprSemantics(
                context,
                path,
                program,
                module_name,
                &call_typed,
            );
            if (!canonicalTypeIsVoidLike(context, return_type_id)) {
                try recordExprSink(context, call_expr, .@"return");
            }
            args_owned_by_call = true;

            const body = try allocator.alloc(sir.Stmt, 1);
            errdefer allocator.free(body);
            body[0] = if (canonicalTypeIsVoidLike(context, return_type_id))
                .{ .expr = call_expr }
            else
                .{ .@"return" = call_expr };

            const decl_id = (try registerGeneratedDecl(
                context,
                module_name,
                null,
                name,
                .function,
            )) orelse return error.SemanticFailed;
            try context.generic.instantiated_functions.append(allocator, .{
                .decl_id = decl_id,
                .module_name = module_name,
                .owner = null,
                .name = name,
                .abi_name = null,
                .is_extern = false,
                .is_export = false,
                .calling_convention = .c,
                .params = params,
                .return_type_id = return_type_id,
                .debug_token = debug_token,
                .body = body,
            });

            return name;
        }
        /// The canonical type ids a specialization substituted, in declaration order.
        /// A `const_usize` argument specializes a declaration but appears in no type.
        pub fn specializationTypeIds(allocator: std.mem.Allocator, args: ?[]const semantic_types.GenericArgument) SemaError![]const semantic_types.TypeId {
            const arguments = args orelse return &.{};
            var count: usize = 0;
            for (arguments) |arg| {
                if (arg == .type) count += 1;
            }
            if (count == 0) return &.{};
            const ids = try allocator.alloc(semantic_types.TypeId, count);
            errdefer allocator.free(ids);
            var index: usize = 0;
            for (arguments) |arg| switch (arg) {
                .type => |type_id| {
                    ids[index] = type_id;
                    index += 1;
                },
                .const_usize => {},
            };
            return ids;
        }
        pub fn checkedMethodUse(
            context: *SemaContext,
            call: ast.MethodCall,
            authority: ?CheckedMethodAuthority,
            callee_declaration_id: ?identity.DeclId,
            result_type_id: semantic_types.TypeId,
            substitution: ?[]const semantic_types.GenericArgument,
        ) SemaError!?sir.CheckedMethodUse {
            const selected = authority orelse return null;
            const type_ids = try specializationTypeIds(context.allocator, substitution);
            return .{
                .use_id = selected.use_id,
                .source_declaration_id = context.function_state.active_source_decl_id.?,
                .source_offset = call.method_token.offset,
                .protocol_id = selected.protocol,
                .method_id = selected.method,
                .callee_declaration_id = callee_declaration_id,
                .result_type_id = result_type_id,
                .substitution = type_ids,
            };
        }
        pub fn checkedProtocolForMethodUse(context: *SemaContext, path: []const u8, module_name: []const u8, call: ast.MethodCall) SemaError!?CheckedMethodAuthority {
            var selected: ?CheckedMethodAuthority = null;
            const source_decl_id = context.function_state.active_source_decl_id orelse return null;
            for (context.generic.method_use_records.items) |requirement| {
                const protocol = requirement.declared_protocol orelse continue;
                if (requirement.declaration_id == null or requirement.declaration_id.? != source_decl_id or
                    !std.mem.eql(u8, requirement.module_name, module_name) or
                    requirement.source_offset != call.method_token.offset or
                    !std.mem.eql(u8, requirement.operation, call.method)) continue;
                const method_id = protocol.method_id orelse return error.SemanticFailed;
                const use_id = requirement.use_id orelse return error.SemanticFailed;
                if (selected != null and (selected.?.protocol != protocol.id or selected.?.method != method_id or selected.?.use_id != use_id)) {
                    try context.diagnostic_context.emitToken(path, call.method_token, "generic method `{s}` has incompatible checked protocol authorities", .{call.method});
                    return error.SemanticFailed;
                }
                selected = .{ .protocol = protocol.id, .method = method_id, .use_id = use_id };
            }
            return selected;
        }
        /// Canonical type of a generic binder at its definition site: the binder
        /// itself, identified by the scope it was declared in and its position there.
        pub fn canonicalGenericParameterTypeId(
            context: *SemaContext,
            module_name: []const u8,
            params: []const ast.GenericParam,
            ordinal: u32,
        ) SemaError!?semantic_types.TypeId {
            const scopes = context.generic_scopes orelse return null;
            if (ordinal >= params.len) return null;
            const id = scopes.sourceParam(module_name, params[ordinal].name_token.offset) orelse return null;
            if (!scopes.verifyParam(id)) return null;
            return try internCanonicalNode(&context.canonical.types.?, .{ .generic_parameter = .{
                .scope = id.scope,
                .ordinal = id.ordinal,
                .name = params[ordinal].name,
            } });
        }
        pub fn canonicalGenericParameterOf(context: *SemaContext, type_id: semantic_types.TypeId) ?semantic_types.GenericParameterRef {
            const node = canonicalTypeNode(context, type_id);
            if (node.* != .generic_parameter) return null;
            return node.generic_parameter;
        }
        /// At its definition site a generic binder stands for an unknown concrete type,
        /// so a form that needs the concrete kind -- a field, an index, a dereference, a
        /// call, an operator, a loop, or a switch -- cannot be lowered there. The trial
        /// body carries the receiver through as a projection of its generic shape
        /// instead: every method use the body makes is still recorded and admitted
        /// against the binder's declared protocol, and each specialization re-lowers the
        /// form with the substituted concrete type.
        pub fn deferConcreteKindForm(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            receiver: *TypedExpr,
            out: *sir.Expr,
        ) SemaError!TypedExpr {
            out.* = receiver.expr.*;
            allocator.destroy(receiver.expr);
            // The caller's error path still owns a node, so hand it the deferred one.
            receiver.expr = out;
            var deferred = makeTypedExprFromIdWithProvenance(out, receiver.type_id, receiver.provenance.derived());
            deferred.value_semantics = receiver.value_semantics;
            deferred.generic_shape = try context.generic.shapes.project(allocator, receiver.generic_shape);
            deferred.generic_origin = projectedOrigin(receiver.generic_origin);
            try finalizeAndRecordExprSemantics(context, path, program, current_module, &deferred);
            return deferred;
        }
        /// A stand-in type for an operation whose result kind cannot be decided at the
        /// definition site, e.g. the payload of `try` over a binder-typed result.
        pub fn definitionSiteDeferredType(context: *SemaContext, name: []const u8) SemaError!semantic_types.TypeId {
            context.generic.definition_site_deferred_counter += 1;
            return try internCanonicalNode(&context.canonical.types.?, .{ .generic_parameter = .{
                .scope = @fromBackingInt(@intCast(std.math.maxInt(u32))),
                .ordinal = @intCast(std.math.maxInt(u32) - context.generic.definition_site_deferred_counter),
                .name = name,
            } });
        }
        pub fn deferredDefinitionSiteValue(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            receiver: *TypedExpr,
            out: *sir.Expr,
            result_type_id: semantic_types.TypeId,
            result_shape: *const generic_shapes.Shape,
        ) SemaError!TypedExpr {
            out.* = receiver.expr.*;
            allocator.destroy(receiver.expr);
            receiver.expr = out;
            var deferred = makeTypedExprFromIdWithProvenance(out, result_type_id, receiver.provenance.derived());
            deferred.value_semantics = receiver.value_semantics;
            deferred.generic_shape = result_shape;
            deferred.generic_origin = projectedOrigin(receiver.generic_origin);
            try recordDeferredShape(context, result_type_id, result_shape);
            try finalizeAndRecordExprSemantics(context, path, program, current_module, &deferred);
            return deferred;
        }
        /// A specialization where every binder stands for itself. A declaration with a
        /// const-value binder has no canonical type to stand in for the value, so its
        /// body is reported as a coverage gap rather than lowered.
        pub fn placeholderGenericArgs(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            module_name: []const u8,
            params: []const ast.GenericParam,
        ) SemaError!?[]semantic_types.GenericArgument {
            if (params.len == 0) return null;
            for (params) |param| if (param.is_const_value) return null;
            const args = try allocator.alloc(semantic_types.GenericArgument, params.len);
            errdefer allocator.free(args);
            for (args, 0..) |*arg, ordinal| {
                const type_id = try canonicalGenericParameterTypeId(context, module_name, params, @intCast(ordinal)) orelse return null;
                arg.* = .{ .type = type_id };
            }
            return args;
        }
        /// Record one lowered method use and return its stable use id. Lowering owns
        /// the record: the same source use lowered again under a different
        /// specialization reuses the id it was first recorded with.
        pub fn recordMethodUse(context: *SemaContext, requirement: sir.GenericRequirement) SemaError!u32 {
            const allocator = context.allocator;
            const key = MethodUseKey{
                .declaration_id = requirement.declaration_id orelse return error.SemanticFailed,
                .offset = requirement.source_offset,
            };
            if (context.generic.method_use_index.get(key)) |use_id| return use_id;
            const use_id = context.generic.next_generated_use_id;
            context.generic.next_generated_use_id += 1;
            try context.generic.method_use_index.put(allocator, key, use_id);
            return use_id;
        }
        /// Keep the checked record for a method use the lowering produced. Lowering is
        /// the only writer of these records: a source use creates exactly one record,
        /// and every specialization of that use reads the record the body made.
        pub fn recordMethodUseRequirement(context: *SemaContext, requirement: sir.GenericRequirement) SemaError!u32 {
            const allocator = context.allocator;
            const use_id = try recordMethodUse(context, requirement);
            for (context.generic.method_use_records.items) |existing| {
                if (existing.declaration_id == requirement.declaration_id and
                    existing.source_offset == requirement.source_offset and
                    std.mem.eql(u8, existing.parameter, requirement.parameter) and
                    std.mem.eql(u8, existing.operation, requirement.operation)) return use_id;
            }
            var stored = requirement;
            stored.use_id = use_id;
            try context.generic.method_use_records.append(allocator, stored);
            return use_id;
        }
        /// Record an operation the lowered body performs on a value whose shape still
        /// stands for a generic binder. A declaration's inferred requirements are the
        /// operations its own definition-site lowering reaches, so no separate walk of
        /// the declaration's syntax is needed to know them.
        pub fn recordLoweredOperationUse(
            context: *SemaContext,
            operation: []const u8,
            token: lexer.Token,
            receiver: TypedExpr,
        ) SemaError!void {
            const allocator = context.allocator;
            const registry = context.declarations.registry orelse return;
            const scopes = context.generic_scopes orelse return;
            const source_decl_id = context.function_state.active_source_decl_id orelse return;
            const decl = registry.decl(source_decl_id) orelse return;
            const decl_module = registry.module(decl.module) orelse return;

            var origins: std.ArrayListUnmanaged(GenericReceiverOrigin) = .empty;
            defer origins.deinit(allocator);
            try receiverOrigins(allocator, receiver, &origins);
            for (origins.items) |origin| {
                for (context.generic.method_use_records.items) |existing| {
                    if (existing.declaration_id == source_decl_id and existing.source_offset == token.offset and
                        existing.projected == origin.projected and
                        std.mem.eql(u8, existing.parameter, origin.parameter.name) and
                        std.mem.eql(u8, existing.operation, operation)) return;
                }
                try context.generic.method_use_records.append(allocator, .{
                    .declaration_id = source_decl_id,
                    .projected = origin.projected,
                    .module_name = decl_module.name,
                    .owner = decl.owner,
                    .declaration = decl.name,
                    .parameter = origin.parameter.name,
                    .parameter_definition_offset = origin.parameter.name_token.offset,
                    .parameter_id = scopes.sourceParam(origin.module_name, origin.parameter.name_token.offset) orelse return error.SemanticFailed,
                    .operation = operation,
                    .source_offset = token.offset,
                });
                definitionSiteTrace("lower-record", decl.owner, decl.name, operation);
            }
        }
        /// Record the method use lowering is about to emit. The authority is created by
        /// the body that makes the use, never by a parallel walk of the declaration's
        /// syntax, so the record the checked flow sees is the record lowering lowered.
        pub fn recordLoweredMethodUse(
            context: *SemaContext,
            program: ast.Program,
            call: ast.MethodCall,
            receiver_expr: TypedExpr,
            protocol_id: identity.DeclId,
        ) SemaError!?CheckedMethodAuthority {
            const registry = context.declarations.registry orelse return null;
            const scopes = context.generic_scopes orelse return null;
            const source_decl_id = context.function_state.active_source_decl_id orelse return null;
            const decl = registry.decl(source_decl_id) orelse return null;
            const decl_module = registry.module(decl.module) orelse return null;
            const protocol_decl = try protocols.declarationForId(protocols.contextFromSession(SemaContext, context), program, protocol_id);
            const method = try protocols.methodOf(protocol_decl, call.method);
            const method_id = try registeredDeclId(context, protocol_decl.module_name, protocol_decl.name, method.name, .protocol_method);

            var origins: std.ArrayListUnmanaged(GenericReceiverOrigin) = .empty;
            defer origins.deinit(context.allocator);
            try receiverOrigins(context.allocator, receiver_expr, &origins);
            if (origins.items.len == 0) return null;

            var selected: ?CheckedMethodAuthority = null;
            for (origins.items) |origin| {
                const use_id = try recordMethodUseRequirement(context, .{
                    .projected = origin.projected,
                    .declaration_id = source_decl_id,
                    .module_name = decl_module.name,
                    .owner = decl.owner,
                    .declaration = decl.name,
                    .parameter = origin.parameter.name,
                    .parameter_definition_offset = origin.parameter.name_token.offset,
                    .parameter_id = scopes.sourceParam(origin.module_name, origin.parameter.name_token.offset) orelse return error.SemanticFailed,
                    .operation = call.method,
                    .source_offset = call.method_token.offset,
                    .declared_protocol = .{
                        .id = protocol_id,
                        .method_id = method_id,
                        .module_name = protocol_decl.module_name,
                        .name = protocol_decl.name,
                    },
                });
                if (selected != null and selected.?.use_id != use_id) return error.SemanticFailed;
                selected = CheckedMethodAuthority{ .protocol = protocol_id, .method = method_id, .use_id = use_id };
            }
            return selected;
        }
        /// Method authority for a call whose receiver is a generic binder itself, as
        /// seen at the declaration's definition site. The binder's declared protocol
        /// constraints are the authority: no concrete witness exists yet, so the use is
        /// recorded from the lowered body rather than reconstructed from the source.
        pub fn genericBinderMethodAuthority(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            call: ast.MethodCall,
            receiver_type: semantic_types.TypeId,
            qualified: ?identity.DeclId,
        ) SemaError!?CheckedMethodAuthority {
            const binder = canonicalGenericParameterOf(context, receiver_type) orelse return null;
            const scopes = context.generic_scopes orelse return null;
            const declared = scopes.paramDecl(.{ .scope = binder.scope, .ordinal = binder.ordinal }) orelse return null;
            const registry = context.declarations.registry orelse return null;
            const source_decl_id = context.function_state.active_source_decl_id orelse return null;
            const decl = registry.decl(source_decl_id) orelse return null;
            const decl_module = registry.module(decl.module) orelse return null;
            const protocol_id = try declaredGenericMethodProtocol(context, path, program, GenericReceiverOrigin{
                .parameter = declared,
                .module_name = decl_module.name,
            }, call, qualified);
            const protocol_decl = try protocols.declarationForId(protocols.contextFromSession(SemaContext, context), program, protocol_id);
            const method = try protocols.methodOf(protocol_decl, call.method);
            const method_id = try registeredDeclId(context, protocol_decl.module_name, protocol_decl.name, method.name, .protocol_method);
            const use_id = try recordMethodUseRequirement(context, .{
                .declaration_id = source_decl_id,
                .module_name = decl_module.name,
                .owner = decl.owner,
                .declaration = decl.name,
                .parameter = binder.name,
                .parameter_definition_offset = declared.name_token.offset,
                .parameter_id = .{ .scope = binder.scope, .ordinal = binder.ordinal },
                .operation = call.method,
                .source_offset = call.method_token.offset,
                .declared_protocol = .{
                    .id = protocol_id,
                    .method_id = method_id,
                    .module_name = protocol_decl.module_name,
                    .name = protocol_decl.name,
                },
            });
            return CheckedMethodAuthority{ .protocol = protocol_id, .method = method_id, .use_id = use_id };
        }
        /// The declared contract a binder method use lowers to: the protocol method's
        /// signature with the receiver form as `Self` and no body. One contract per
        /// (protocol method, receiver form) is generated, and the checked body flow
        /// settles the use against that declared return type. The contract is a
        /// declaration inside sema only: it is never emitted or specialized.
        pub fn genericBinderContractFunction(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            receiver_type: semantic_types.TypeId,
            protocol_decl: ast.ProtocolDecl,
            protocol_id: identity.DeclId,
            method: ast.ProtocolMethod,
        ) SemaError!usize {
            const method_id = try registeredDeclId(context, protocol_decl.module_name, protocol_decl.name, method.name, .protocol_method);
            for (context.generic.generic_contract_index.items, 0..) |existing, index| {
                if (existing.receiver == receiver_type and existing.protocol == protocol_id and existing.method == method_id) return index;
            }
            const name = try std.fmt.allocPrint(allocator, "{s}{d}_{d}_{d}", .{
                generated_names.generic_contract_prefix,
                @backingInt(protocol_id),
                @backingInt(method_id),
                @backingInt(receiver_type),
            });
            // Once the contract is staged, its spelling and parameters are owned by
            // the staged function; an error after that point unwinds the stage itself
            // instead of freeing pieces the stage already took over.
            var staged = false;
            errdefer if (!staged) allocator.free(name);
            const params = try allocator.alloc(sir.Param, method.params.len);
            errdefer if (!staged) allocator.free(params);
            for (method.params, 0..) |param, index| {
                params[index] = .{
                    .name = param.name,
                    .type_id = try parseTypeWithBindings(context, path, program, protocol_decl.module_name, param.type_name, receiver_type, &.{}, &.{}),
                };
            }
            const return_type = if (method.return_type) |type_name|
                try parseTypeWithBindings(context, path, program, protocol_decl.module_name, type_name, receiver_type, &.{}, &.{})
            else
                try canonicalPrimitiveTypeId(context, .void);
            const decl_id = (try registerGeneratedDecl(context, protocol_decl.module_name, protocol_decl.name, name, .function)) orelse return error.SemanticFailed;
            try context.generic.generic_contract_functions.append(allocator, .{
                .decl_id = decl_id,
                .module_name = protocol_decl.module_name,
                .owner = protocol_decl.name,
                .name = name,
                .is_extern = true,
                .params = params,
                .return_type_id = return_type,
                .debug_token = method.name_token,
                .body = &.{},
            });
            staged = true;
            errdefer {
                if (context.generic.generic_contract_functions.pop()) |owned| allocator.free(owned.params);
                allocator.free(name);
            }
            try context.generic.generic_contract_index.append(allocator, GenericContractFunction{
                .receiver = receiver_type,
                .protocol = protocol_id,
                .method = method_id,
                .decl_id = decl_id,
                .name = name,
                .return_type = return_type,
            });
            return context.generic.generic_contract_functions.items.len - 1;
        }
        pub fn receiverTraversesAlias(context: *SemaContext, expr: *const sir.Expr) bool {
            if (semanticExprMetadata(context, expr)) |metadata| {
                if (metadata.non_owning_place_origin) return true;
                switch (canonicalTypeKind(context, metadata.type_id)) {
                    .ref, .slice => return true,
                    else => {},
                }
            }
            return switch (expr.*) {
                .field, .borrowed_field => |field| receiverTraversesAlias(context, field.object),
                .index, .borrowed_index => |index| receiverTraversesAlias(context, index.object),
                else => false,
            };
        }
        pub fn rejectBorrowedResourceTransfer(context: *SemaContext, path: []const u8, program: ast.Program, lowered: *const sir.Expr, expected: semantic_types.TypeId, token: lexer.Token, action: []const u8) SemaError!void {
            if (!try typeIsOwnedValue(context, path, program, expected)) return;
            const metadata = semanticExprMetadata(context, lowered) orelse return error.SemanticFailed;
            if (!metadata.non_owning_place_origin) return;
            try context.diagnostic_context.emitToken(path, token, "cannot consume a resource {s} through a borrowed place; move the owner or use a borrowed receiver", .{action});
            return SemaError.SemanticFailed;
        }
        pub fn expectNoExplicitMethodTypeArgs(context: *SemaContext, path: []const u8, call: ast.MethodCall) SemaError!void {
            if (call.type_args.len != 0) {
                try context.diagnostic_context.emitToken(path, call.method_token, "method `{s}` does not accept explicit type arguments", .{call.method});
                return SemaError.SemanticFailed;
            }
        }
        pub fn expectZeroArgLenMethod(context: *SemaContext, path: []const u8, call: ast.MethodCall, owner_name: []const u8) SemaError!void {
            if (call.args.len != 0) {
                try context.diagnostic_context.emitToken(path, call.method_token, "{s}.len expects no arguments", .{owner_name});
                return SemaError.SemanticFailed;
            }
        }
        pub fn expectZeroArgClearMethod(context: *SemaContext, path: []const u8, call: ast.MethodCall, owner_name: []const u8) SemaError!void {
            if (call.args.len != 0) {
                try context.diagnostic_context.emitToken(path, call.method_token, "{s}.clear expects no arguments", .{owner_name});
                return SemaError.SemanticFailed;
            }
        }
        pub fn expectOneArgMethod(context: *SemaContext, path: []const u8, call: ast.MethodCall, owner_name: []const u8, method_name: []const u8) SemaError!void {
            if (call.args.len != 1) {
                try context.diagnostic_context.emitToken(path, call.method_token, "{s}.{s} expects one argument", .{ owner_name, method_name });
                return SemaError.SemanticFailed;
            }
        }
        pub fn prepareMutableContainerMethod(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            object_expr: *ast.Expr,
            object_type: semantic_types.TypeId,
            owner_name: []const u8,
            method_token: lexer.Token,
            mutation_action: []const u8,
        ) SemaError!void {
            try expectMutableReceiver(context, path, program, current_module, globals, locals, object_expr, object_type, owner_name);
            try rejectLiveBorrowContainerMutationConflict(context, path, program, current_module, globals, locals, object_expr, owner_name, method_token, mutation_action);
        }
        pub fn instantiateGenericFunctionFromCall(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            call_token: lexer.Token,
            function: ast.Function,
            explicit_type_args: []const ast.TypeName,
            original_args: []const ast.CallArg,
            lowered_args: []const TypedExpr,
        ) SemaError!ConcreteCall {
            if (function.owner != null) {
                try context.diagnostic_context.emitToken(path, function.name_token, "generic methods are not implemented yet", .{});
                return SemaError.SemanticFailed;
            }
            const resolved_args = if (explicit_type_args.len != 0)
                try resolveExplicitGenericArgs(context, path, program, current_module, function, explicit_type_args)
            else
                try inferGenericArgsFromCall(context, path, program, current_module, function, lowered_args, null);
            defer context.allocator.free(resolved_args);
            return instantiateGenericFunctionFromResolvedCall(context, allocator, path, program, current_module, globals, locals, call_token, function, resolved_args, original_args, lowered_args);
        }
        pub fn instantiateGenericFunctionFromResolvedCall(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            call_token: lexer.Token,
            function: ast.Function,
            resolved_args: []const semantic_types.GenericArgument,
            original_args: []const ast.CallArg,
            lowered_args: []const TypedExpr,
        ) SemaError!ConcreteCall {
            if (function.owner != null) {
                try context.diagnostic_context.emitToken(path, function.name_token, "generic methods are not implemented yet", .{});
                return SemaError.SemanticFailed;
            }
            const concrete_function = instantiateGenericFunction(context, allocator, path, program, globals, function, resolved_args) catch |err| {
                if (err == error.SemanticFailed) {
                    const labels = [_]diagnostics.Label{.{
                        .span = declarationSpan(program, path, function.module_name, function.name_token),
                        .message = "generic declaration introduced the unmet operation here",
                    }};
                    const notes = [_][]const u8{"the concrete generic function body failed semantic validation at its definition site"};
                    try context.diagnostic_context.emitTokenWith(path, call_token, .{
                        .code = .generic_inference,
                        .labels = &labels,
                        .notes = &notes,
                        .help = "review the inferred operations required by this generic declaration",
                    }, "generic function `{s}` is unavailable for these type arguments", .{function.name});
                }
                return err;
            };
            var arg_exprs = try allocator.alloc(*sir.Expr, lowered_args.len);
            errdefer allocator.free(arg_exprs);

            const saved_params = context.function_state.current_generic_params;
            const saved_args = context.function_state.current_generic_args;
            context.function_state.current_generic_params = function.type_params;
            context.function_state.current_generic_args = resolved_args;
            defer {
                context.function_state.current_generic_params = saved_params;
                context.function_state.current_generic_args = saved_args;
            }

            for (function.params, lowered_args, original_args, 0..) |param, lowered, original, i| {
                const expected = try parseType(context, path, program, function.module_name, param.type_name);
                try expectType(context, path, firstExprToken(original.value), expected, lowered.type_id);
                try rejectScopedAllocCallEscape(context, path, program, locals, original.value, expected, "function call");
                try rejectProjectedResourceTransferForTypedValue(context, path, program, firstExprToken(original.value), lowered, expected, "function call");
                try lowerImplicitHandoff(context, path, program, locals, original.value, expected, lowered.expr);
                try markCheckedNamedHandoff(context, path, program, @constCast(locals), original.value, lowered.expr, expected);
                arg_exprs[i] = lowered.expr;
            }
            const return_type = concrete_function.return_type_id orelse try canonicalPrimitiveTypeId(context, .void);
            const return_provenance = try inferredCallReturnProvenance(context, path, program, current_module, globals, locals, return_type, original_args, function, function.type_params, resolved_args);
            return .{
                .module_name = concrete_function.module_name,
                .owner = concrete_function.owner,
                .name = concrete_function.name,
                .return_type_id = return_type,
                .return_provenance = return_provenance,
                .arg_exprs = arg_exprs,
            };
        }
        pub fn normalizeHostedSharePayload(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            payload: *TypedExpr,
            expected: semantic_types.TypeId,
        ) SemaError!void {
            if (payload.type_id == expected) return;
            const actual_kind = canonicalTypeKind(context, payload.type_id);
            const expected_kind = canonicalTypeKind(context, expected);
            if (!((actual_kind == .int and expected_kind == .int) or
                (actual_kind == .float and expected_kind == .float))) return error.SemanticFailed;
            const converted = try allocator.create(sir.Expr);
            converted.* = .{ .cast = .{
                .subject = payload.expr,
                .target_type_id = expected,
                .union_case_name = null,
                .fallible = false,
                .reinterpret = false,
            } };
            payload.* = makeTypedExprFromId(converted, expected);
            try finalizeAndRecordExprSemantics(context, path, program, current_module, payload);
        }
        pub fn lowerHostedSyncSharePrimitive(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            locals: []const LocalBinding,
            out: *sir.Expr,
            call: ast.Call,
            callee: ast.Function,
            resolved_args: []const semantic_types.GenericArgument,
            lowered_args: []TypedExpr,
        ) SemaError!?TypedExpr {
            if (intrinsics.resolveDeclaration(callee.module_name, callee.owner, callee.name) != .std_sync_share or
                resolved_args.len != 1)
            {
                return null;
            }
            if (lowered_args.len != 1) return null;

            const payload_type_id = resolved_args[0].type;
            try normalizeHostedSharePayload(context, allocator, path, program, current_module, &lowered_args[0], payload_type_id);
            try rejectProjectedResourceTransferForTypedValue(context, path, program, firstExprToken(call.args[0].value), lowered_args[0], payload_type_id, "function call");
            try lowerImplicitHandoff(context, path, program, locals, call.args[0].value, payload_type_id, lowered_args[0].expr);
            try markCheckedNamedHandoff(context, path, program, @constCast(locals), call.args[0].value, lowered_args[0].expr, payload_type_id);

            const primitive_contract = intrinsics.definition(.std_sync_share_boxed);
            const resolved_primitive = findAstFunctionExact(context, program, primitive_contract.module_name.?, primitive_contract.owner, primitive_contract.name) orelse {
                try context.diagnostic_context.emitToken(path, callee.name_token, "std.sync internal shared-value construction requires hosted primitive `share_boxed`", .{});
                return SemaError.SemanticFailed;
            };
            const primitive = resolved_primitive.decl;
            const return_type = try resolvedFunctionReturnType(context, path, program, callee, callee.type_params, resolved_args);
            out.* = .{ .sync_share_boxed = .{
                .intrinsic_id = .std_sync_share,
                .decl_id = resolved_primitive.id,
                .module_name = primitive.module_name,
                .owner = primitive.owner,
                .callee = primitive.name,
                .payload = lowered_args[0].expr,
                .payload_type_id = payload_type_id,
                .return_type_id = return_type,
            } };
            return try makeTypedExpr(context, out, return_type);
        }
        pub fn lowerHostedOwnArcPrimitive(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            locals: []const LocalBinding,
            out: *sir.Expr,
            call: ast.Call,
            callee: ast.Function,
            resolved_args: []const semantic_types.GenericArgument,
            lowered_args: []TypedExpr,
        ) SemaError!?TypedExpr {
            if (intrinsics.resolveDeclaration(callee.module_name, callee.owner, callee.name) != .std_own_arc or
                resolved_args.len != 1)
            {
                return null;
            }
            if (lowered_args.len != 1) return null;

            const payload_type_id = resolved_args[0].type;
            try normalizeHostedSharePayload(context, allocator, path, program, current_module, &lowered_args[0], payload_type_id);
            if (try typeMayCarryBorrowedProvenance(context, path, program, current_module, payload_type_id)) {
                try context.diagnostic_context.emitToken(path, firstExprToken(call.args[0].value), "Arc payload cannot carry borrowed/view data; store owned values or synchronized resources instead", .{});
                return SemaError.SemanticFailed;
            }

            try rejectProjectedResourceTransferForTypedValue(context, path, program, firstExprToken(call.args[0].value), lowered_args[0], payload_type_id, "function call");
            try lowerImplicitHandoff(context, path, program, locals, call.args[0].value, payload_type_id, lowered_args[0].expr);
            try markCheckedNamedHandoff(context, path, program, @constCast(locals), call.args[0].value, lowered_args[0].expr, payload_type_id);

            const primitive_contract = intrinsics.definition(.std_own_arc_new_boxed);
            const resolved_primitive = findAstFunctionExact(context, program, primitive_contract.module_name.?, primitive_contract.owner, primitive_contract.name) orelse {
                try context.diagnostic_context.emitToken(path, callee.name_token, "std.own.arc requires hosted primitive `arc_new_boxed`", .{});
                return SemaError.SemanticFailed;
            };
            const primitive = resolved_primitive.decl;
            const return_type = try resolvedFunctionReturnType(context, path, program, callee, callee.type_params, resolved_args);
            out.* = .{ .sync_share_boxed = .{
                .intrinsic_id = .std_own_arc,
                .decl_id = resolved_primitive.id,
                .module_name = primitive.module_name,
                .owner = primitive.owner,
                .callee = primitive.name,
                .payload = lowered_args[0].expr,
                .payload_type_id = payload_type_id,
                .return_type_id = return_type,
            } };
            return try makeTypedExpr(context, out, return_type);
        }
        pub fn lowerHostedThreadSpawnPrimitive(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            out: *sir.Expr,
            call: ast.Call,
            callee: ast.Function,
            resolved_args: []const semantic_types.GenericArgument,
            lowered_args: []const TypedExpr,
        ) SemaError!?TypedExpr {
            if (intrinsics.resolveDeclaration(callee.module_name, callee.owner, callee.name) != .std_thread_spawn or
                resolved_args.len != 1)
            {
                return null;
            }
            if (lowered_args.len != 2) return null;

            const primitive_contract = intrinsics.definition(.std_thread_spawn_boxed);
            const resolved_primitive = findAstFunctionExact(context, program, primitive_contract.module_name.?, primitive_contract.owner, primitive_contract.name) orelse {
                try context.diagnostic_context.emitToken(path, call.callee_token, "std.thread.spawn requires hosted primitive `spawn_boxed`", .{});
                return SemaError.SemanticFailed;
            };
            const primitive = resolved_primitive.decl;
            const entry_name = switch (call.args[0].value.*) {
                .name => |name| name,
                else => {
                    try context.diagnostic_context.emitToken(path, firstExprToken(call.args[0].value), "std.thread.spawn requires a named entrypoint", .{});
                    return SemaError.SemanticFailed;
                },
            };
            const resolved_entry = findAstFunction(context, program, current_module, null, entry_name.text) orelse {
                try context.diagnostic_context.emitToken(path, entry_name.token, "std.thread.spawn entrypoint `{s}` is not a known function", .{entry_name.text});
                return SemaError.SemanticFailed;
            };
            const entry = resolved_entry.decl;
            const trampoline_name = try synthesizeHostedThreadTrampoline(context, allocator, path, program, entry, resolved_args[0].type);
            const return_type = if (primitive.return_type) |type_name|
                try parseCanonicalType(context, path, program, primitive.module_name, type_name)
            else
                try canonicalPrimitiveTypeId(context, .void);
            lowered_args[0].expr.destroy(allocator);
            out.* = .{ .thread_spawn_boxed = .{
                .intrinsic_id = .std_thread_spawn,
                .decl_id = resolved_primitive.id,
                .module_name = primitive.module_name,
                .owner = primitive.owner,
                .callee = primitive.name,
                .trampoline = .{
                    .decl_id = maybeRegisteredDeclId(context, entry.module_name, null, trampoline_name, .function),
                    .module_name = entry.module_name,
                    .owner = null,
                    .name = trampoline_name,
                },
                .payload = lowered_args[1].expr,
                .payload_type_id = resolved_args[0].type,
                .return_type_id = return_type,
            } };
            return try makeTypedExpr(context, out, return_type);
        }
        pub fn lowerHostedTaskGroupSpawnPrimitive(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            out: *sir.Expr,
            call: ast.Call,
            callee: ast.Function,
            resolved_args: []const semantic_types.GenericArgument,
            lowered_args: []const TypedExpr,
        ) SemaError!?TypedExpr {
            const spawn_kind = intrinsics.resolveDeclaration(callee.module_name, callee.owner, callee.name) orelse return null;
            if (spawn_kind != .std_task_group_spawn_impl and
                spawn_kind != .std_task_group_spawn_context_impl and
                spawn_kind != .std_task_context_spawn_impl) return null;
            if (resolved_args.len != 2 or resolved_args[0] != .type or resolved_args[1] != .type or lowered_args.len != 3) return error.SemanticFailed;
            const primitive_contract = intrinsics.definition(if (spawn_kind == .std_task_context_spawn_impl)
                .std_task_context_spawn_boxed
            else
                .std_task_group_spawn_boxed);
            const resolved_primitive = findAstFunctionExact(context, program, primitive_contract.module_name.?, primitive_contract.owner, primitive_contract.name) orelse {
                try context.diagnostic_context.emitToken(path, call.callee_token, "std.thread.TaskGroup.spawn requires hosted primitive `task_group_spawn_boxed`", .{});
                return error.SemanticFailed;
            };
            const primitive = resolved_primitive.decl;
            const input_type = resolved_args[0].type;
            const result_type = resolved_args[1].type;
            const trampoline_name = try synthesizeTaskGroupTrampoline(context, allocator, path, program, callee.module_name, call.callee_token, input_type, result_type, spawn_kind != .std_task_group_spawn_impl);
            const return_type = try parseCanonicalType(context, path, program, primitive.module_name, primitive.return_type orelse return error.SemanticFailed);
            out.* = .{ .task_group_spawn_boxed = .{
                .intrinsic_id = spawn_kind,
                .decl_id = resolved_primitive.id,
                .module_name = primitive.module_name,
                .owner = primitive.owner,
                .callee = primitive.name,
                .trampoline = .{
                    .decl_id = maybeRegisteredDeclId(context, callee.module_name, null, trampoline_name, .function),
                    .module_name = callee.module_name,
                    .owner = null,
                    .name = trampoline_name,
                },
                .group_raw = lowered_args[0].expr,
                .entry = lowered_args[1].expr,
                .payload = lowered_args[2].expr,
                .payload_type_id = input_type,
                .result_type_id = result_type,
                .return_type_id = return_type,
            } };
            return try makeTypedExpr(context, out, return_type);
        }
        pub fn lowerHostedTaskResultTakePrimitive(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            out: *sir.Expr,
            callee: ast.Function,
            resolved_args: []const semantic_types.GenericArgument,
            lowered_args: []const TypedExpr,
        ) SemaError!?TypedExpr {
            if (intrinsics.resolveDeclaration(callee.module_name, callee.owner, callee.name) != .std_task_result_take_impl) return null;
            if (resolved_args.len != 1 or resolved_args[0] != .type or lowered_args.len != 2) return error.SemanticFailed;
            const return_type = try parseTypeWithBindings(
                context,
                path,
                program,
                callee.module_name,
                callee.return_type orelse return error.SemanticFailed,
                null,
                callee.type_params,
                resolved_args,
            );
            out.* = .{ .task_result_take = .{
                .witness = lowered_args[0].expr,
                .pointer = lowered_args[1].expr,
                .value_type_id = resolved_args[0].type,
                .return_type_id = return_type,
            } };
            return try makeTypedExpr(context, out, return_type);
        }
        pub fn resolveExplicitGenericArgs(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            function: ast.Function,
            explicit_type_args: []const ast.TypeName,
        ) SemaError![]semantic_types.GenericArgument {
            const allocator = context.allocator;
            if (function.type_params.len != explicit_type_args.len) {
                const token = if (explicit_type_args.len != 0) explicit_type_args[0].token else function.name_token;
                try generics.emitGenericArity(&context.diagnostic_context, path, program, token, function.module_name, function.name_token, .function, function.name, function.type_params.len, explicit_type_args.len);
                return SemaError.SemanticFailed;
            }

            var resolved = try allocator.alloc(semantic_types.GenericArgument, explicit_type_args.len);
            errdefer allocator.free(resolved);
            for (explicit_type_args, function.type_params, 0..) |arg, param, i| {
                resolved[i] = try resolveGenericArgument(context, path, program, current_module, arg, param, null, context.function_state.current_generic_params, context.function_state.current_generic_args, 0);
                if (!param.is_const_value) {
                    try protocols.expectGenericParamProtocolConformance(SemaContext, typeIsOwnedForProtocol, context, path, program, function.module_name, param, arg.token, resolved[i].type);
                }
            }
            return resolved;
        }
        pub fn selectSliceViewMethod(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            receiver_type: semantic_types.TypeId,
            writable: bool,
            token: lexer.Token,
        ) SemaError!?ast.Function {
            const decl = canonicalBaseStructDecl(context, program, receiver_type) orelse return null;
            var const_method: ?ast.Function = null;
            var mutable_method: ?ast.Function = null;
            for (decl.methods) |method| {
                if (!method.is_slice_view or !canAccessDecl(context, current_module, method.module_name, method.is_pub)) continue;
                const slot = if (method.params[0].type_name.ref_is_const) &const_method else &mutable_method;
                if (slot.*) |previous| {
                    try context.diagnostic_context.emitToken(path, token, "ambiguous `syntax.slice_view` methods `{s}` and `{s}`", .{ previous.name, method.name });
                    return SemaError.SemanticFailed;
                }
                slot.* = method;
            }
            return if (writable) mutable_method orelse const_method else const_method;
        }
        /// Resolve an inherent method from the canonical receiver type rather
        /// than the requester's short-name scope, so same-named structs from
        /// different modules cannot supply each other's methods.
        pub fn findCanonicalStructMethod(
            context: *SemaContext,
            program: ast.Program,
            current_module: []const u8,
            receiver_type: semantic_types.TypeId,
            name: []const u8,
        ) ?ast.Function {
            const decl = canonicalBaseStructDecl(context, program, receiver_type) orelse return null;
            for (decl.methods) |method| {
                if (std.mem.eql(u8, method.name, name) and
                    canAccessDecl(context, current_module, method.module_name, method.is_pub)) return method;
            }
            return null;
        }
        pub fn sliceReceiverWritable(context: *SemaContext, program: ast.Program, current_module: []const u8, globals: []const GlobalBinding, locals: []const LocalBinding, object: *ast.Expr, object_type: semantic_types.TypeId) bool {
            if (canonicalTypeKind(context, object_type) == .ref and canonicalRefIsConst(context, object_type)) return false;
            if (resolvePlace(context, program, current_module, globals, locals, object)) |place| return place.access.allowsMutation();
            return switch (object.*) {
                .name, .field, .index, .deref, .address_of => false,
                else => true,
            };
        }
        pub fn resolveLocalPlaceTypeForBorrowedHook(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            locals: []const LocalBinding,
            expr: *ast.Expr,
        ) SemaError!?semantic_types.TypeId {
            var reversed_steps: std.ArrayListUnmanaged(TakeAstStep) = .empty;
            defer reversed_steps.deinit(allocator);
            const root_name = try collectLocalRootAndStepsNoDiagnostic(allocator, expr, &reversed_steps) orelse return null;
            const local = findLocal(locals, root_name.text) orelse return null;
            var current_type_id = if (local.kind(context) == .ref) canonicalRefTarget(context, local.type_id) else local.type_id;
            var i: usize = reversed_steps.items.len;
            while (i > 0) {
                i -= 1;
                switch (reversed_steps.items[i]) {
                    .field => |field| {
                        const resolved = try typeStructFieldOrNull(context, path, program, current_module, current_type_id, field.field) orelse return null;
                        current_type_id = resolved.field_type_id;
                    },
                    .index => {
                        if (try type_resolution.typeIndexAccessRole(typeConstructionContext(context), current_type_id)) |role| {
                            current_type_id = role.value_type_id;
                        } else {
                            return null;
                        }
                    },
                }
            }
            return current_type_id;
        }
        pub fn typeStructFieldOrNull(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            type_id: semantic_types.TypeId,
            field_name: []const u8,
        ) SemaError!?struct {
            field_type_id: semantic_types.TypeId,
        } {
            if (canonicalTypeKind(context, type_id) != .@"struct") return null;
            const decl = canonicalStructLookup(context, program, type_id) orelse return null;
            const decl_field = lookupStructField(decl, field_name) orelse return null;
            if (!canAccessDecl(context, current_module, decl.module_name, decl_field.is_pub)) return null;
            const field_type = try structFieldTypeId(context, path, program, decl, decl_field);
            return .{ .field_type_id = field_type };
        }
        pub fn collectLocalRootAndStepsNoDiagnostic(
            allocator: std.mem.Allocator,
            expr: *ast.Expr,
            reversed_steps: *std.ArrayListUnmanaged(TakeAstStep),
        ) SemaError!?ast.Name {
            var cursor = expr;
            while (true) {
                switch (cursor.*) {
                    .field => |field| {
                        try reversed_steps.append(allocator, .{ .field = field });
                        cursor = field.object;
                    },
                    .index => |index| {
                        try reversed_steps.append(allocator, .{ .index = index });
                        cursor = index.object;
                    },
                    .name => |name| return name,
                    else => return null,
                }
            }
        }
        pub fn inferredCallReturnProvenance(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            return_type: semantic_types.TypeId,
            args: []const ast.CallArg,
            function: ast.Function,
            generic_params: ?[]const ast.GenericParam,
            generic_args: ?[]const semantic_types.GenericArgument,
        ) SemaError!Provenance {
            if (!try typeMayCarryBorrowedProvenance(context, path, program, current_module, return_type)) return .none();

            const allocator = context.allocator;
            var summary_relation = try summarizeBorrowEscapeRelation(context, path, program, current_module, globals, function, generic_params, generic_args);
            defer summary_relation.deinit(allocator);

            var combined = Provenance.none();
            for (args, function.params, 0..) |arg, param, i| {
                if (!summary_relation.relation.returnsSource(function.params, summary_relation.source_can_borrow, i)) continue;
                const param_type = if (generic_params) |bindings|
                    try parseTypeWithBindings(context, path, program, function.module_name, param.type_name, null, bindings, generic_args.?)
                else
                    try parseType(context, path, program, function.module_name, param.type_name);
                combined = Provenance.combine(combined, try borrowForwardingResultArgProvenance(context, path, program, current_module, globals, locals, arg.value, param_type));
            }
            return try propagatedProvenanceForTypeId(context, path, program, current_module, return_type, combined);
        }
        pub fn inferredMethodReturnProvenance(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            return_type: semantic_types.TypeId,
            receiver_provenance: Provenance,
            receiver_type: semantic_types.TypeId,
            args: []const ast.CallArg,
            method: ast.Function,
            generic_params: ?[]const ast.GenericParam,
            generic_args: ?[]const semantic_types.GenericArgument,
        ) SemaError!Provenance {
            if (!try typeMayCarryBorrowedProvenance(context, path, program, current_module, return_type)) return .none();

            const allocator = context.allocator;
            var summary_relation = try summarizeBorrowEscapeRelation(context, path, program, current_module, globals, method, generic_params, generic_args);
            defer summary_relation.deinit(allocator);

            var combined = Provenance.none();
            if (summary_relation.relation.returnsSource(method.params, summary_relation.source_can_borrow, 0)) {
                combined = Provenance.combine(combined, try borrowForwardingValueProvenance(context, path, program, current_module, receiver_type, receiver_provenance));
            }
            for (args, method.params[1..], 0..) |arg, param, i| {
                if (!summary_relation.relation.returnsSource(method.params, summary_relation.source_can_borrow, i + 1)) continue;
                const param_type = if (generic_params) |bindings|
                    try parseTypeWithBindings(context, path, program, method.module_name, param.type_name, null, bindings, generic_args.?)
                else
                    try parseType(context, path, program, method.module_name, param.type_name);
                combined = Provenance.combine(combined, try borrowForwardingResultArgProvenance(context, path, program, current_module, globals, locals, arg.value, param_type));
            }
            return try propagatedProvenanceForTypeId(context, path, program, current_module, return_type, combined);
        }
        pub fn borrowForwardingArgProvenance(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            expr: *ast.Expr,
            param_type: semantic_types.TypeId,
        ) SemaError!Provenance {
            if (canonicalTypeKind(context, param_type) == .ref) {
                return (try exprProvenanceAs(context, path, program, current_module, globals, locals, expr, canonicalRefTarget(context, param_type))).derived();
            }
            if (!try typeMayCarryBorrowedProvenance(context, path, program, current_module, param_type)) return .none();
            return try exprProvenanceAs(context, path, program, current_module, globals, locals, expr, param_type);
        }
        pub fn borrowForwardingResultArgProvenance(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            expr: *ast.Expr,
            param_type: semantic_types.TypeId,
        ) SemaError!Provenance {
            const value = try borrowForwardingArgProvenance(context, path, program, current_module, globals, locals, expr, param_type);
            if (value.hasBorrow() or canonicalTypeKind(context, param_type) != .ref) return value;
            // A returned borrow from a named owned argument depends on its place
            // even though the owned value type carries no borrowed provenance.
            if (expr.* == .name) {
                if (findLocal(locals, expr.name.text)) |local| {
                    if (local.kind(context) == .owned)
                        return placeRootProvenance(context, path, program, current_module, globals, locals, expr);
                }
            } else if (expr.* == .field or expr.* == .index) {
                if (try resolveLocalPlaceTypeForBorrowedHook(context, context.allocator, path, program, current_module, locals, expr)) |place_type| {
                    if (canonicalTypeKind(context, place_type) == .owned)
                        return placeRootProvenance(context, path, program, current_module, globals, locals, expr);
                }
            }
            return value;
        }
        pub fn borrowForwardingValueProvenance(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            value_type: semantic_types.TypeId,
            provenance: Provenance,
        ) SemaError!Provenance {
            if (canonicalTypeKind(context, value_type) == .ref) return provenance.derived();
            if (!try typeMayCarryBorrowedProvenance(context, path, program, current_module, value_type)) return .none();
            return provenance;
        }
        pub fn rejectBorrowedCallStateEscapes(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            args: []const ast.CallArg,
            function: ast.Function,
            generic_params: ?[]const ast.GenericParam,
            generic_args: ?[]const semantic_types.GenericArgument,
        ) SemaError!void {
            const allocator = context.allocator;
            var summary_relation = try summarizeBorrowEscapeRelation(context, path, program, current_module, globals, function, generic_params, generic_args);
            defer summary_relation.deinit(allocator);

            if (args.len != function.params.len) return;
            for (function.params, args, 0..) |param, arg, source_index| {
                const source_type = if (generic_params) |bindings|
                    try parseTypeWithBindings(context, path, program, function.module_name, param.type_name, null, bindings, generic_args.?)
                else
                    try parseType(context, path, program, function.module_name, param.type_name);
                if (canonicalTypeKind(context, source_type) == .ref and !canonicalRefIsConst(context, source_type))
                    try rejectProjectedBindingWritableCall(context, path, program, current_module, globals, locals, arg.value);
                const source_provenance = try borrowForwardingArgProvenance(context, path, program, current_module, globals, locals, arg.value, source_type);
                if (!source_provenance.hasBorrow()) continue;

                if (summary_relation.relation.escapesToGlobalSource(function.params, summary_relation.source_can_borrow, source_index) and !provenanceCanEscapeFunction(locals, source_provenance)) {
                    try emitCallBorrowEscape(context, path, locals, firstExprToken(arg.value), source_provenance);
                    return SemaError.SemanticFailed;
                }

                var sink_index: usize = 0;
                while (sink_index < function.params.len) : (sink_index += 1) {
                    if (!summary_relation.relation.escapesToSinkSource(function.params, summary_relation.source_can_borrow, source_index, sink_index)) continue;
                    const sink_param = function.params[sink_index];
                    const sink_type = if (generic_params) |bindings|
                        try parseTypeWithBindings(context, path, program, function.module_name, sink_param.type_name, null, bindings, generic_args.?)
                    else
                        try parseType(context, path, program, function.module_name, sink_param.type_name);
                    const target = try callEscapeTarget(context, path, program, current_module, globals, locals, args[sink_index].value, sink_type);
                    if (!provenanceOutlivesTarget(locals, source_provenance, target)) {
                        try emitCallBorrowEscape(context, path, locals, firstExprToken(arg.value), source_provenance);
                        return SemaError.SemanticFailed;
                    }
                }
            }
        }
        pub fn rejectBorrowedMethodStateEscapes(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            call: ast.MethodCall,
            method: ast.Function,
            self_type: semantic_types.TypeId,
            generic_params: ?[]const ast.GenericParam,
            generic_args: ?[]const semantic_types.GenericArgument,
        ) SemaError!void {
            const allocator = context.allocator;
            var summary_relation = try summarizeBorrowEscapeRelation(context, path, program, current_module, globals, method, generic_params, generic_args);
            defer summary_relation.deinit(allocator);

            if (method.params.len != call.args.len + 1) return;
            if (canonicalTypeKind(context, self_type) == .ref and !canonicalRefIsConst(context, self_type))
                try rejectProjectedBindingWritableCall(context, path, program, current_module, globals, locals, call.object);
            var source_index: usize = 0;
            while (source_index < method.params.len) : (source_index += 1) {
                const source_type = if (source_index == 0)
                    self_type
                else if (generic_params) |bindings|
                    try parseTypeWithBindings(context, path, program, method.module_name, method.params[source_index].type_name, null, bindings, generic_args.?)
                else
                    try parseType(context, path, program, method.module_name, method.params[source_index].type_name);
                const source_expr = if (source_index == 0) call.object else call.args[source_index - 1].value;
                if (source_index != 0 and canonicalTypeKind(context, source_type) == .ref and !canonicalRefIsConst(context, source_type))
                    try rejectProjectedBindingWritableCall(context, path, program, current_module, globals, locals, source_expr);
                const source_provenance = try borrowForwardingArgProvenance(context, path, program, current_module, globals, locals, source_expr, source_type);
                if (!source_provenance.hasBorrow()) continue;

                if (summary_relation.relation.escapesToGlobalSource(method.params, summary_relation.source_can_borrow, source_index) and !provenanceCanEscapeFunction(locals, source_provenance)) {
                    try emitCallBorrowEscape(context, path, locals, firstExprToken(source_expr), source_provenance);
                    return SemaError.SemanticFailed;
                }

                var sink_index: usize = 0;
                while (sink_index < method.params.len) : (sink_index += 1) {
                    if (!summary_relation.relation.escapesToSinkSource(method.params, summary_relation.source_can_borrow, source_index, sink_index)) continue;
                    const sink_type = if (sink_index == 0)
                        self_type
                    else if (generic_params) |bindings|
                        try parseTypeWithBindings(context, path, program, method.module_name, method.params[sink_index].type_name, null, bindings, generic_args.?)
                    else
                        try parseType(context, path, program, method.module_name, method.params[sink_index].type_name);
                    const sink_expr = if (sink_index == 0) call.object else call.args[sink_index - 1].value;
                    const target = try callEscapeTarget(context, path, program, current_module, globals, locals, sink_expr, sink_type);
                    if (!provenanceOutlivesTarget(locals, source_provenance, target)) {
                        try emitCallBorrowEscape(context, path, locals, firstExprToken(source_expr), source_provenance);
                        return SemaError.SemanticFailed;
                    }
                }
            }
        }
        pub fn tryErrorWidenOrdinal(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            target: semantic_types.TypeId,
            source: semantic_types.TypeId,
            token: lexer.Token,
        ) SemaError!?u32 {
            if (target == source or canonicalTypeKind(context, source) != .@"enum") return null;
            if (canonicalTypeNode(context, target).* == .error_union) {
                for (canonicalTypeNode(context, target).error_union, 0..) |member, index| {
                    if (member == source) return @intCast(index);
                }
                return null;
            }
            if (canonicalTypeKind(context, target) != .@"union") return null;
            const decl_id = canonicalNominalDeclId(context, target) orelse return null;
            const decl = lookupUnionDeclById(context, program, decl_id) orelse {
                try context.diagnostic_context.emitToken(path, token, "unknown result error union", .{});
                return SemaError.SemanticFailed;
            };
            if (decl.kind != .type_union) return null;
            var match: ?u32 = null;
            for (decl.variants, 0..) |variant, index| {
                const member = try parseCanonicalType(context, path, program, decl.module_name, variant);
                if (member != source) continue;
                if (match != null) return null;
                match = @intCast(index);
            }
            return match;
        }

        pub fn typeUnionVariantCaseName(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            target: semantic_types.TypeId,
            actual: semantic_types.TypeId,
            token: lexer.Token,
        ) SemaError!?[]const u8 {
            if (canonicalTypeKind(context, target) != .@"union") return null;
            if (canonicalTypeNode(context, target).* == .error_union) {
                for (canonicalTypeNode(context, target).error_union) |member| {
                    if (member == actual) {
                        const case_name = try formatCanonicalTypeDisplay(context, member);
                        errdefer context.allocator.free(case_name);
                        try context.output.generated_strings.append(allocator, case_name);
                        return case_name;
                    }
                }
                return null;
            }
            const union_name = canonicalNominalDeclName(context, program, target) orelse return null;
            const decl_id = canonicalNominalDeclId(context, target) orelse return null;
            const decl = lookupUnionDeclById(context, program, decl_id) orelse {
                try context.diagnostic_context.emitToken(path, token, "unknown union `{s}`", .{union_name});
                return SemaError.SemanticFailed;
            };
            if (decl.kind != .type_union) return null;
            for (decl.variants) |variant| {
                const variant_type = try parseCanonicalType(context, path, program, decl.module_name, variant);
                if (variant_type == actual) {
                    const case_name = try formatCanonicalTypeDisplay(context, variant_type);
                    errdefer context.allocator.free(case_name);
                    try context.output.generated_strings.append(allocator, case_name);
                    return case_name;
                }
            }
            return null;
        }
        pub fn storageMarkerTargetType(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            target: ast.TypeName,
            expected_type_id: ?semantic_types.TypeId,
        ) SemaError!semantic_types.TypeId {
            if (target.args.len == 0) {
                if (std.mem.eql(u8, target.name, "[:]")) {
                    if (expected_type_id) |expected| {
                        if (canonicalTypeKind(context, expected) == .dense_array) return expected;
                    }
                } else if (std.mem.eql(u8, target.name, "[;]")) {
                    if (expected_type_id) |expected| {
                        if (canonicalTypeKind(context, expected) == .sparse_array) return expected;
                    }
                }
            }
            return parseCanonicalType(context, path, program, current_module, target);
        }
        pub fn inferSparseKeyedLiteralCapacity(context: *SemaContext, path: []const u8, literal: ast.KeyedLiteral) SemaError!usize {
            var capacity: usize = 0;
            for (literal.entries) |entry| {
                if (entry.key.* != .int) {
                    try context.diagnostic_context.emitToken(path, firstExprToken(entry.key), "sparse keyed construction without explicit capacity requires integer literal indices", .{});
                    return SemaError.SemanticFailed;
                }
                const index = entry.key.int.value;
                if (index < 0) {
                    try context.diagnostic_context.emitToken(path, entry.key.int.token, "sparse storage keyed index {d} cannot be negative", .{index});
                    return SemaError.SemanticFailed;
                }
                const next: usize = @as(usize, @intCast(index)) + 1;
                if (next > capacity) capacity = next;
            }
            return capacity;
        }
        pub fn sequenceFactoryVisible(context: *SemaContext, program: ast.Program, requester: []const u8, factory: ast.Function) bool {
            if (!canAccessDecl(context, requester, factory.module_name, factory.is_pub)) return false;
            if (std.mem.eql(u8, requester, factory.module_name) or isAutoloadModule(program, factory.module_name)) return true;
            const imports = if (findModuleInfo(program, requester)) |info| info.imports else program.imports;
            for (imports) |decl| {
                if (!std.mem.eql(u8, decl.path, factory.module_name)) continue;
                if (decl.items.len == 0) return true;
                for (decl.items) |item| {
                    if (std.mem.eql(u8, item.name, factory.name)) return true;
                }
            }
            return false;
        }
        pub fn matchSequenceReturn(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            module: []const u8,
            pattern: ast.TypeName,
            actual: semantic_types.TypeId,
            params: []const ast.GenericParam,
            bindings: []?semantic_types.GenericArgument,
        ) SemaError!bool {
            if (!typeNameContainsGenericParam(pattern, params)) return try parseCanonicalType(context, path, program, module, pattern) == actual;
            const node = canonicalTypeNode(context, actual).*;
            var inner = pattern;
            if (pattern.is_ref) {
                if (canonicalTypeKind(context, actual) != .ref or canonicalRefIsConst(context, actual) != pattern.ref_is_const) return false;
                inner.is_ref = false;
                inner.ref_is_const = false;
                return matchSequenceReturn(context, path, program, module, inner, canonicalRefTarget(context, actual), params, bindings);
            }
            if (pattern.is_owned) {
                if (node != .owned) return false;
                inner.is_owned = false;
                return matchSequenceReturn(context, path, program, module, inner, canonicalOwnedTarget(context, actual), params, bindings);
            }
            if (pattern.is_optional) {
                if (node != .optional) return false;
                inner.is_optional = false;
                return matchSequenceReturn(context, path, program, module, inner, node.optional, params, bindings);
            }
            if (pattern.is_raw) {
                if (node != .raw or node.raw.is_const != pattern.raw_is_const or node.raw.is_volatile != pattern.is_volatile_raw) return false;
                return matchSequenceReturn(context, path, program, module, rawPointeeTypeName(pattern), node.raw.target, params, bindings);
            }
            if (pattern.is_slice) {
                if (node != .slice or node.slice.is_const != pattern.slice_flags.is_const) return false;
                inner.is_slice = false;
                inner.is_optional = pattern.slice_flags.item_is_optional;
                return matchSequenceReturn(context, path, program, module, inner, node.slice.item, params, bindings);
            }
            if (pattern.array_len != null or pattern.array_len_name != null) {
                if (node != .array) return false;
                if (pattern.array_len) |len| if (len != node.array.len) return false;
                if (pattern.array_len_name) |name| {
                    for (params, 0..) |param, index| {
                        if (!param.is_const_value or !std.mem.eql(u8, param.name, name)) continue;
                        const value: semantic_types.GenericArgument = .{ .const_usize = node.array.len };
                        if (bindings[index]) |bound| {
                            if (!generics.argumentsEqual(&.{bound}, &.{value})) return false;
                        } else bindings[index] = value;
                    }
                }
                inner.array_len = null;
                inner.array_len_name = null;
                return matchSequenceReturn(context, path, program, module, inner, node.array.item, params, bindings);
            }
            for (params, 0..) |param, index| {
                if (param.is_const_value or pattern.module_name != null or !std.mem.eql(u8, param.name, pattern.name) or pattern.args.len != 0) continue;
                if (bindings[index]) |bound| return bound == .type and bound.type == actual;
                bindings[index] = .{ .type = actual };
                return true;
            }
            if (pattern.args.len == 1 and std.mem.eql(u8, pattern.name, "[:]") and node == .dense_array)
                return matchSequenceReturn(context, path, program, module, pattern.args[0], node.dense_array, params, bindings);
            if (pattern.args.len == 1 and std.mem.eql(u8, pattern.name, "[;]") and node == .sparse_array)
                return matchSequenceReturn(context, path, program, module, pattern.args[0], node.sparse_array, params, bindings);
            if (std.mem.eql(u8, pattern.name, "result") and pattern.args.len == 2 and node == .result) {
                return try matchSequenceReturn(context, path, program, module, pattern.args[0], node.result.ok, params, bindings) and
                    try matchSequenceReturn(context, path, program, module, pattern.args[1], node.result.err, params, bindings);
            }
            if (pattern.is_function or pattern.is_arrow_callable) {
                if (node != .callable or node.callable.params.len != pattern.function_params.len or
                    node.callable.kind != (if (pattern.is_arrow_callable) semantic_types.CallableKind.arrow else .function) or
                    node.callable.calling_convention != (if (pattern.function_calling_convention == .c) semantic_types.CallingConvention.c else .cyna)) return false;
                for (pattern.function_params, node.callable.params) |param, ty| {
                    if (!try matchSequenceReturn(context, path, program, module, param, ty, params, bindings)) return false;
                }
                if (pattern.function_return_type) |result| return matchSequenceReturn(context, path, program, module, result.*, node.callable.return_type, params, bindings);
                return canonicalTypeKind(context, node.callable.return_type) == .void;
            }
            const lookup_module = try typeLookupModule(context, path, program, module, pattern);
            const resolved_alias = resolveTypeAliasInTypeScope(canonical.sourceContext(context), program, module, lookup_module, pattern.name);
            if (resolved_alias == .found) {
                const alias = resolved_alias.found.alias;
                if (!alias.is_distinct and alias.type_params.len == pattern.args.len) {
                    const alias_bindings = try context.allocator.alloc(?semantic_types.GenericArgument, alias.type_params.len);
                    defer context.allocator.free(alias_bindings);
                    @memset(alias_bindings, null);
                    if (!try matchSequenceReturn(context, path, program, alias.module_name, alias.target, actual, alias.type_params, alias_bindings)) return false;
                    for (pattern.args, alias_bindings) |arg, bound| {
                        const value = bound orelse return false;
                        if (value != .type or !try matchSequenceReturn(context, path, program, module, arg, value.type, params, bindings)) return false;
                    }
                    return true;
                }
            }
            if (findInstantiatedStructForCanonicalType(context, actual)) |instantiated| {
                const resolved = resolveStructInTypeScope(canonical.sourceContext(context), program, module, lookup_module, pattern.name);
                if (resolved != .found) return false;
                const decl = resolved.found.decl;
                if (!std.mem.eql(u8, decl.module_name, instantiated.module_name) or !std.mem.eql(u8, decl.name, instantiated.base_name) or pattern.args.len != instantiated.type_args.len) return false;
                for (pattern.args, instantiated.type_args) |arg, value| {
                    switch (value) {
                        .type => |ty| if (!try matchSequenceReturn(context, path, program, module, arg, ty, params, bindings)) return false,
                        .const_usize => |number| {
                            var matched = false;
                            for (params, 0..) |param, index| {
                                if (!param.is_const_value or !std.mem.eql(u8, param.name, arg.name)) continue;
                                if (bindings[index]) |bound| {
                                    if (bound != .const_usize or bound.const_usize != number) return false;
                                } else bindings[index] = value;
                                matched = true;
                            }
                            if (!matched and arg.const_value != number) return false;
                        },
                    }
                }
                return true;
            }
            return false;
        }
        pub fn genericArrayLenForName(params: []const ast.GenericParam, args: []const semantic_types.GenericArgument, name: []const u8) ?usize {
            return generics.arrayLenForName(params, args, name);
        }
        pub fn typeNameContainsGenericParam(type_name: ast.TypeName, params: []const ast.GenericParam) bool {
            return generics.typeNameContainsParam(type_name, params);
        }
        pub fn resolveGenericArgument(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            arg: ast.TypeName,
            param: ast.GenericParam,
            self_type: ?semantic_types.TypeId,
            generic_params: []const ast.GenericParam,
            generic_args: []const semantic_types.GenericArgument,
            depth: usize,
        ) SemaError!semantic_types.GenericArgument {
            return generics.resolveArgument(SemaContext, parseTypeDepth, context, path, program, current_module, arg, param, self_type, generic_params, generic_args, depth);
        }
        fn formatInstantiatedStructName(context: *SemaContext, base_name: []const u8, args: []const semantic_types.GenericArgument) SemaError![]const u8 {
            return generics.formatInstantiatedStructName(SemaContext, canonical.appendTypeDisplay, context, base_name, args);
        }

        pub fn instantiateGenericFunction(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            globals: []const GlobalBinding,
            function: ast.Function,
            inferred_args: []const semantic_types.GenericArgument,
        ) SemaError!sir.Function {
            return generics.instantiateFunction(
                context,
                allocator,
                path,
                program,
                globals,
                function,
                inferred_args,
                formatInstantiatedStructName,
                lowerFunctionNamed,
            );
        }
        pub fn instantiateGenericStructMethod(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            globals: []const GlobalBinding,
            lowered_owner: []const u8,
            method: ast.Function,
            type_params: []const ast.GenericParam,
            type_args: []const semantic_types.GenericArgument,
        ) SemaError!sir.Function {
            const definition_path = moduleSourcePath(program, method.module_name, path);
            return generics.instantiateStructMethod(
                context,
                allocator,
                definition_path,
                program,
                globals,
                lowered_owner,
                method,
                type_params,
                type_args,
                formatInstantiatedStructName,
                lowerFunctionSpecialized,
            );
        }
        pub fn instantiateGenericStructMethodForCall(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            globals: []const GlobalBinding,
            lowered_owner: []const u8,
            method_token: lexer.Token,
            method: ast.Function,
            type_params: []const ast.GenericParam,
            type_args: []const semantic_types.GenericArgument,
        ) SemaError!sir.Function {
            return instantiateGenericStructMethod(context, allocator, path, program, globals, lowered_owner, method, type_params, type_args) catch |err| {
                if (err == error.SemanticFailed) {
                    try context.diagnostic_context.emitTokenWith(path, method_token, .{
                        .notes = &.{"the concrete generic method body failed semantic validation at its definition site"},
                        .help = "review this operation's ownership requirements for the receiver's element, key, and value types",
                    }, "method `{s}` is unavailable for receiver `{s}` with these type arguments", .{ method.name, lowered_owner });
                }
                return err;
            };
        }
        pub fn typeNameIsBareName(pattern: ast.TypeName) bool {
            return pattern.args.len == 0 and pattern.array_len == null and pattern.array_len_name == null and
                !pattern.is_ref and !pattern.is_owned and !pattern.is_raw and !pattern.is_volatile_raw and
                !pattern.is_optional and !pattern.is_slice and !pattern.is_function and !pattern.is_arrow_callable and
                pattern.const_value == null;
        }
        /// A generic call that takes a binder-typed value in a container position fills
        /// its type parameter through that container: what the call hands back is that
        /// binder projected out of it. The canonical result type names only the binder,
        /// so the lowering records the projection on the result.
        pub fn typeNameProjectsParam(pattern: ast.TypeName, parameter_name: []const u8) bool {
            if (pattern.args.len == 0 and pattern.array_len == null and pattern.array_len_name == null and
                !pattern.is_ref and !pattern.is_owned and !pattern.is_raw and !pattern.is_volatile_raw and
                !pattern.is_optional and !pattern.is_slice and !pattern.is_function and !pattern.is_arrow_callable and
                pattern.const_value == null)
                return std.mem.eql(u8, pattern.name, parameter_name);
            for (pattern.args) |argument| if (typeNameProjectsParam(argument, parameter_name)) return true;
            if (pattern.raw_target) |target| return typeNameProjectsParam(target.*, parameter_name);
            if (pattern.is_function or pattern.is_arrow_callable) {
                for (pattern.function_params) |argument| if (typeNameProjectsParam(argument, parameter_name)) return true;
                if (pattern.function_return_type) |ret| return typeNameProjectsParam(ret.*, parameter_name);
                return false;
            }
            var inner = pattern;
            inner.args = &.{};
            inner.array_len = null;
            inner.array_len_name = null;
            inner.array_len_token = null;
            inner.is_slice = false;
            inner.is_optional = false;
            inner.is_ref = false;
            inner.is_owned = false;
            inner.is_raw = false;
            inner.is_volatile_raw = false;
            inner.is_function = false;
            inner.is_arrow_callable = false;
            inner.is_const_value_arg = false;
            inner.const_value = null;
            return typeNameProjectsParam(inner, parameter_name);
        }
        pub fn genericCallProjectionOrigin(
            context: *SemaContext,
            callee: ast.Function,
            args: []const TypedExpr,
        ) SemaError!?GenericReceiverOrigin {
            const return_type = callee.return_type orelse return null;
            if (!typeNameProjectsParam(return_type, return_type.name)) return null;
            for (callee.type_params) |parameter| {
                if (parameter.is_const_value or !std.mem.eql(u8, parameter.name, return_type.name)) continue;
                for (callee.params, args) |parameter_decl, actual| {
                    const pattern = parameter_decl.type_name;
                    // A bare binder argument is not a projection: the result is the
                    // binder itself, with its full declaration-site authority.
                    if (typeNameIsBareName(pattern)) continue;
                    if (!typeNameProjectsParam(pattern, parameter.name)) continue;
                    if (!type_resolution.containsDefinitionSiteBinder(canonicalTypeInterner(context), actual.type_id)) continue;
                    const origin = canonicalReceiverOrigin(context, actual.type_id, false) orelse continue;
                    return projectedOrigin(origin);
                }
            }
            return null;
        }
        pub fn inferGenericArgsFromCall(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            function: ast.Function,
            actual_args: anytype,
            expected_type_id: ?semantic_types.TypeId,
        ) SemaError![]semantic_types.GenericArgument {
            _ = current_module;
            const allocator = context.allocator;
            const inferred = try allocator.alloc(?semantic_types.GenericArgument, function.type_params.len);
            defer allocator.free(inferred);
            @memset(inferred, null);

            for (function.params, actual_args) |param, actual| {
                const type_id = if (comptime @TypeOf(actual) == ?TypedExpr)
                    if (actual) |value| value.type_id else continue
                else
                    actual.type_id;
                try unifyGenericBinding(context, path, program, function.module_name, param.type_name, type_id, function.type_params, inferred);
            }

            if (expected_type_id) |expected| {
                if (function.return_type) |return_type| {
                    // Arguments already determine these binders. Re-unifying a
                    // result-valued binder against a flattened contextual
                    // result would mistake its payload for the full binder.
                    var needs_return_inference = false;
                    for (inferred) |binding| {
                        if (binding == null) needs_return_inference = true;
                    }
                    if (!return_type.is_inferred_result_return and needs_return_inference)
                        try unifyGenericBinding(context, path, program, function.module_name, return_type, expected, function.type_params, inferred);
                }
            }

            var result = try allocator.alloc(semantic_types.GenericArgument, function.type_params.len);
            errdefer allocator.free(result);
            for (function.type_params, inferred, 0..) |param, maybe_ty, i| {
                const ty = maybe_ty orelse {
                    try generics.emitGenericInferenceFailure(&context.diagnostic_context, path, program, function.module_name, param, .function);
                    return SemaError.SemanticFailed;
                };
                if (!param.is_const_value) {
                    try protocols.expectGenericParamProtocolConformance(SemaContext, typeIsOwnedForProtocol, context, path, program, function.module_name, param, param.name_token, ty.type);
                }
                result[i] = ty;
            }
            return result;
        }
        /// The element type a definition-site container stands for, if it is a
        /// container at all: `[2]T`, `[]const T`, `?T`, `&const T`, `*T`, and owned
        /// values all still hold an unresolved concrete item.
        pub fn definitionSiteItemTypeId(context: *SemaContext, type_id: semantic_types.TypeId) ?semantic_types.TypeId {
            const node = canonicalTypeNode(context, type_id);
            switch (node.*) {
                .array => return node.array.item,
                .dense_array => return node.dense_array,
                .sparse_array => return node.sparse_array,
                .slice => return node.slice.item,
                .optional => return node.optional,
                .ref_ => return node.ref_.target,
                .owned => return node.owned,
                .raw => return node.raw.target,
                else => return null,
            }
        }
        pub fn unifyGenericBinding(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            pattern: ast.TypeName,
            actual: semantic_types.TypeId,
            generic_params: []const ast.GenericParam,
            inferred: []?semantic_types.GenericArgument,
        ) SemaError!void {
            for (generic_params, 0..) |param, i| {
                if (std.mem.eql(u8, pattern.name, param.name) and pattern.args.len == 0 and !pattern.is_ref and !pattern.is_owned and !pattern.is_raw and !pattern.is_volatile_raw and !pattern.is_optional and !pattern.is_slice and pattern.array_len == null and pattern.array_len_name == null) {
                    if (param.is_const_value) return;
                    if (inferred[i]) |existing| {
                        if (existing != .type or existing.type != actual) {
                            try expectType(context, path, pattern.token, existing.type, actual);
                        }
                    } else {
                        inferred[i] = .{ .type = actual };
                    }
                    return;
                }
            }

            if (std.mem.eql(u8, pattern.name, "()")) {
                const actual_node = canonicalTypeNode(context, actual);
                if (actual_node.* != .tuple or actual_node.tuple.len != pattern.args.len) return;
                for (pattern.args, actual_node.tuple) |member_pattern, member_type| {
                    try unifyGenericBinding(context, path, program, current_module, member_pattern, member_type, generic_params, inferred);
                }
                return;
            }

            if (std.mem.eql(u8, pattern.name, "result") and pattern.args.len == 2) {
                const actual_node = canonicalTypeNode(context, actual);
                if (actual_node.* != .result) return;
                try unifyGenericBinding(context, path, program, current_module, pattern.args[0], actual_node.result.ok, generic_params, inferred);
                try unifyGenericBinding(context, path, program, current_module, pattern.args[1], actual_node.result.err, generic_params, inferred);
                return;
            }

            // At a definition site an argument whose type still contains a binder has
            // no concrete structure to match. Match the pattern's element layer against
            // the binder it wraps, so `extract(value)` with a `Box<U>` parameter binds
            // `U` to `T` and the specialization re-checks the call when `T` is known.
            if (type_resolution.containsDefinitionSiteBinder(canonicalTypeInterner(context), actual) and
                (pattern.args.len != 0 or pattern.array_len != null or pattern.array_len_name != null or
                    pattern.is_slice or pattern.is_optional or pattern.is_ref or pattern.is_owned or pattern.is_raw))
            {
                if (pattern.args.len != 0) {
                    for (pattern.args) |arg| try unifyGenericBinding(context, path, program, current_module, arg, actual, generic_params, inferred);
                    return;
                }
                var inner = pattern;
                inner.array_len = null;
                inner.array_len_name = null;
                inner.array_len_token = null;
                inner.is_slice = false;
                inner.is_optional = pattern.slice_flags.item_is_optional;
                inner.is_ref = false;
                inner.is_owned = false;
                inner.is_raw = false;
                if (definitionSiteItemTypeId(context, actual)) |item| {
                    return unifyGenericBinding(context, path, program, current_module, inner, item, generic_params, inferred);
                }
                return unifyGenericBinding(context, path, program, current_module, inner, actual, generic_params, inferred);
            }

            if (pattern.is_function or pattern.is_arrow_callable) {
                const actual_node = canonicalTypeNode(context, actual);
                if (actual_node.* != .callable) return;
                const callable = actual_node.callable;
                if (callable.kind != (if (pattern.is_arrow_callable) semantic_types.CallableKind.arrow else .function) or
                    callable.params.len != pattern.function_params.len or
                    callable.calling_convention != (if (pattern.function_calling_convention == .c) semantic_types.CallingConvention.c else .cyna)) return;
                for (pattern.function_params, callable.params) |expected_param, actual_param| {
                    try unifyGenericBinding(context, path, program, current_module, expected_param, actual_param, generic_params, inferred);
                }
                if (pattern.function_return_type) |expected_return| {
                    try unifyGenericBinding(context, path, program, current_module, expected_return.*, callable.return_type, generic_params, inferred);
                }
                return;
            }

            if (pattern.is_ref) {
                if (canonicalTypeKind(context, actual) != .ref) return;
                if (!pattern.ref_is_const and canonicalRefIsConst(context, actual)) return;
                var inner = pattern;
                inner.is_ref = false;
                inner.ref_is_const = false;
                return unifyGenericBinding(context, path, program, current_module, inner, canonicalRefTarget(context, actual), generic_params, inferred);
            }
            if (pattern.is_owned) {
                if (canonicalTypeKind(context, actual) != .owned) return;
                var inner = pattern;
                inner.is_owned = false;
                return unifyGenericBinding(context, path, program, current_module, inner, canonicalOwnedTarget(context, actual), generic_params, inferred);
            }
            if (pattern.is_raw) {
                const actual_node = canonicalTypeNode(context, actual);
                if (actual_node.* != .raw) return;
                const raw = actual_node.raw;
                if (pattern.raw_is_const != raw.is_const) return;
                if (pattern.is_volatile_raw != raw.is_volatile) return;
                const inner = rawPointeeTypeName(pattern);
                return unifyGenericBinding(context, path, program, current_module, inner, raw.target, generic_params, inferred);
            }
            if (pattern.is_optional) {
                if (canonicalTypeKind(context, actual) != .optional) return;
                var inner = pattern;
                inner.is_optional = false;
                return unifyGenericBinding(context, path, program, current_module, inner, canonicalTypeNode(context, actual).optional, generic_params, inferred);
            }
            if (pattern.is_slice) {
                if (canonicalTypeKind(context, actual) != .slice) return;
                var inner = pattern;
                inner.is_slice = false;
                inner.is_optional = pattern.slice_flags.item_is_optional;
                return unifyGenericBinding(context, path, program, current_module, inner, canonicalTypeNode(context, actual).slice.item, generic_params, inferred);
            }
            if (pattern.array_len != null or pattern.array_len_name != null) {
                switch (canonicalTypeNode(context, actual).*) {
                    .array => |array| {
                        if (pattern.array_len) |len| {
                            if (array.len != len) return;
                        }
                        if (pattern.array_len_name) |len_name| {
                            for (generic_params, 0..) |param, i| {
                                if (!param.is_const_value or !std.mem.eql(u8, param.name, len_name)) continue;
                                if (inferred[i]) |existing| {
                                    if (existing != .const_usize or existing.const_usize != array.len) {
                                        try context.diagnostic_context.emitToken(path, pattern.array_len_token orelse pattern.token, "conflicting inferred values for const generic parameter `{s}`", .{param.name});
                                        return SemaError.SemanticFailed;
                                    }
                                } else {
                                    inferred[i] = .{ .const_usize = array.len };
                                }
                                break;
                            }
                        }
                        var inner = pattern;
                        inner.array_len = null;
                        inner.array_len_name = null;
                        inner.array_len_token = null;
                        return unifyGenericBinding(context, path, program, current_module, inner, array.item, generic_params, inferred);
                    },
                    else => return,
                }
            }
            if (std.mem.eql(u8, pattern.name, "[:]") and pattern.args.len == 1) {
                switch (canonicalTypeNode(context, actual).*) {
                    .dense_array => |item| return unifyGenericBinding(context, path, program, current_module, pattern.args[0], item, generic_params, inferred),
                    else => return,
                }
            }
            if (canonicalTypeKind(context, actual) == .@"struct" and pattern.args.len != 0) {
                if (findStruct(context, program, current_module, pattern.name)) |decl| {
                    if (decl.type_params.len == pattern.args.len) {
                        if (findInstantiatedStructForCanonicalType(context, actual)) |instantiated| {
                            if (std.mem.eql(u8, instantiated.base_name, decl.name) and instantiated.type_args.len == pattern.args.len) {
                                for (pattern.args, instantiated.type_args) |pattern_arg, actual_arg| {
                                    try unifyGenericArgumentBinding(context, path, program, current_module, pattern_arg, actual_arg, generic_params, inferred);
                                }
                                return;
                            }
                        }
                    }
                }
            }
        }
        pub fn unifyGenericArgumentBinding(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            pattern: ast.TypeName,
            actual: semantic_types.GenericArgument,
            generic_params: []const ast.GenericParam,
            inferred: []?semantic_types.GenericArgument,
        ) SemaError!void {
            switch (actual) {
                .type => |type_id| return unifyGenericBinding(context, path, program, current_module, pattern, type_id, generic_params, inferred),
                .const_usize => |value| {
                    for (generic_params, 0..) |param, i| {
                        if (!param.is_const_value or !std.mem.eql(u8, pattern.name, param.name)) continue;
                        if (inferred[i]) |existing| {
                            if (existing != .const_usize or existing.const_usize != value) {
                                try context.diagnostic_context.emitToken(path, pattern.token, "conflicting inferred values for const generic parameter `{s}`", .{param.name});
                                return SemaError.SemanticFailed;
                            }
                        } else {
                            inferred[i] = .{ .const_usize = value };
                        }
                        return;
                    }
                    if (!pattern.is_const_value_arg or pattern.const_value.? != value) return;
                },
            }
        }
        pub fn concreteGenericImplOwner(context: *SemaContext, method_owner: []const u8, subject_name: []const u8) SemaError![]const u8 {
            const candidate = try std.fmt.allocPrint(context.allocator, "{s}<{s}>", .{ method_owner, subject_name });
            for (context.output.generated_strings.items) |existing| {
                if (!std.mem.eql(u8, existing, candidate)) continue;
                context.allocator.free(candidate);
                return existing;
            }
            try context.output.generated_strings.append(context.allocator, candidate);
            return candidate;
        }
        pub fn resolveAstFunction(
            context: *SemaContext,
            program: ast.Program,
            requester_module: []const u8,
            owner: ?[]const u8,
            name: []const u8,
        ) SemaError!?ResolvedAstFunction {
            const instantiated_base_name: ?[]const u8 = if (owner) |owner_name|
                if (findInstantiatedStruct(context, owner_name)) |decl| decl.base_name else null
            else
                null;
            return declarations.resolveFunction(
                if (context.declarations.registry) |*registry| registry else null,
                program,
                resolutionPolicy(context),
                instantiated_base_name,
                requester_module,
                owner,
                name,
            );
        }
        pub fn findAstFunctionExact(context: *SemaContext, program: ast.Program, module_name: []const u8, owner: ?[]const u8, name: []const u8) ?ResolvedAstFunction {
            return declarations.findFunctionExact(
                if (context.declarations.registry) |*registry| registry else null,
                program,
                module_name,
                owner,
                name,
            );
        }
        pub fn resolutionPolicy(context: *const SemaContext) name_resolution.AccessPolicy {
            return .{ .friend = if (context.options.test_friend) |friend| .{
                .test_module = friend.test_module,
                .production_module = friend.production_module,
            } else null };
        }
        pub fn findProtocol(context: *const SemaContext, program: ast.Program, requester_module: []const u8, name: []const u8) ?ast.ProtocolDecl {
            return name_resolution.accessibleProtocol(resolutionPolicy(context), program, requester_module, name);
        }
        pub fn findEnumAny(program: ast.Program, name: []const u8) ?ast.EnumDecl {
            return name_resolution.enumAny(program, name);
        }
        pub fn isFlagsType(context: *SemaContext, program: ast.Program, type_id: semantic_types.TypeId) bool {
            const node = canonicalTypeNode(context, type_id);
            if (node.* != .nominal or node.nominal.kind != .@"enum") return false;
            const decl = lookupEnumDeclById(context, program, node.nominal.decl_id) orelse return false;
            return decl.layout == .flags;
        }
        pub fn isUnsignedIntegerType(context: *SemaContext, type_id: semantic_types.TypeId) bool {
            return switch (canonicalTypeNode(context, type_id).*) {
                .integer => |integer| !integer.signed,
                .inferred_integer => false,
                else => false,
            };
        }
        pub fn canonicalRefTypeIdForAccess(context: *SemaContext, target: semantic_types.TypeId, access: ownership_owner.Access) SemaError!semantic_types.TypeId {
            return switch (access) {
                .read_only => canonicalConstRefTypeId(context, target),
                .writable => canonicalRefTypeId(context, target),
            };
        }
        pub fn structFieldTypeId(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            decl: StructLookup,
            field: StructFieldLookup,
        ) SemaError!semantic_types.TypeId {
            if (field.type_id) |type_id| return type_id;
            // Non-instantiated fields belong to their declaration's namespace, never
            // the generic bindings of the function currently projecting the field.
            return parseTypeWithBindings(context, path, program, decl.module_name, field.type_name.?, null, &.{}, &.{});
        }
        pub fn allCanonicalAggregateFieldTypesSatisfy(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            type_id: semantic_types.TypeId,
            comptime predicate: fn (*SemaContext, []const u8, ast.Program, semantic_types.TypeId) SemaError!bool,
        ) SemaError!bool {
            const decl = canonicalStructLookup(context, program, type_id) orelse return false;
            switch (decl.fields) {
                .ast_fields => |fields| for (fields) |field| {
                    const field_ty = try parseType(context, path, program, decl.module_name, field.type_name);
                    if (!try predicate(context, path, program, field_ty)) return false;
                },
                .inst_fields => |fields| for (fields) |field| {
                    if (!try predicate(context, path, program, field.type_id)) return false;
                },
            }
            return true;
        }
        pub fn anyCanonicalAggregateFieldTypeSatisfies(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            type_id: semantic_types.TypeId,
            comptime predicate: fn (*SemaContext, []const u8, ast.Program, semantic_types.TypeId) SemaError!bool,
        ) SemaError!bool {
            if (canonicalStructLookup(context, program, type_id)) |decl| {
                switch (decl.fields) {
                    .ast_fields => |fields| for (fields) |field| {
                        const field_ty = try parseType(context, path, program, decl.module_name, field.type_name);
                        if (try predicate(context, path, program, field_ty)) return true;
                    },
                    .inst_fields => |fields| for (fields) |field| {
                        if (try predicate(context, path, program, field.type_id)) return true;
                    },
                }
                return false;
            }
            if (canonicalUnionLookup(context, program, type_id)) |decl| {
                for (decl.fields) |field| {
                    const type_name = field.type_name orelse continue;
                    const field_ty = try parseType(context, path, program, decl.module_name, type_name);
                    if (try predicate(context, path, program, field_ty)) return true;
                }
                for (decl.variants) |variant| {
                    const variant_ty = try parseType(context, path, program, decl.module_name, variant);
                    if (try predicate(context, path, program, variant_ty)) return true;
                }
            }
            return false;
        }
        pub fn canonicalTypeHasStorageLifetime(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            type_id: semantic_types.TypeId,
        ) SemaError!bool {
            return switch (canonicalTypeNode(context, type_id).*) {
                .primitive => |primitive| primitive == .string,
                .nominal => |nominal| switch (nominal.kind) {
                    .@"struct" => blk: {
                        if (canonicalStructLookup(context, program, type_id)) |decl| {
                            if (decl.is_shared_value) break :blk true;
                        }
                        break :blk try anyCanonicalAggregateFieldTypeSatisfies(context, path, program, type_id, canonicalTypeHasStorageLifetime);
                    },
                    .@"union" => try anyCanonicalAggregateFieldTypeSatisfies(context, path, program, type_id, canonicalTypeHasStorageLifetime),
                    .type_alias => if (nominal.underlying) |underlying|
                        try canonicalTypeHasStorageLifetime(context, path, program, underlying)
                    else
                        false,
                    else => false,
                },
                .generic_instance => |instance| switch (instance.kind) {
                    .@"struct" => blk: {
                        if (canonicalStructLookup(context, program, type_id)) |decl| {
                            if (decl.is_shared_value) break :blk true;
                        }
                        break :blk try anyCanonicalAggregateFieldTypeSatisfies(context, path, program, type_id, canonicalTypeHasStorageLifetime);
                    },
                    else => false,
                },
                .dense_array, .sparse_array, .owned => true,
                .optional => |child| try canonicalTypeHasStorageLifetime(context, path, program, child),
                .array => |array| try canonicalTypeHasStorageLifetime(context, path, program, array.item),
                .tuple => |members| blk: {
                    for (members) |member| {
                        if (try canonicalTypeHasStorageLifetime(context, path, program, member)) break :blk true;
                    }
                    break :blk false;
                },
                .result => |result| try canonicalTypeHasStorageLifetime(context, path, program, result.ok) or
                    try canonicalTypeHasStorageLifetime(context, path, program, result.err),
                else => false,
            };
        }
        pub fn canonicalTypeIsDefaultInitializable(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            type_id: semantic_types.TypeId,
        ) SemaError!bool {
            return switch (canonicalTypeNode(context, type_id).*) {
                .primitive => |primitive| primitive == .bool or primitive == .string,
                .inferred_integer, .inferred_float, .integer, .float => true,
                .nominal => |nominal| switch (nominal.kind) {
                    .@"enum" => true,
                    .@"struct" => try allCanonicalAggregateFieldTypesSatisfy(context, path, program, type_id, canonicalTypeIsDefaultInitializable),
                    .type_alias => if (nominal.underlying) |underlying|
                        try canonicalTypeIsDefaultInitializable(context, path, program, underlying)
                    else
                        false,
                    else => false,
                },
                .generic_instance => |instance| switch (instance.kind) {
                    .@"struct" => try allCanonicalAggregateFieldTypesSatisfy(context, path, program, type_id, canonicalTypeIsDefaultInitializable),
                    else => false,
                },
                .optional => true,
                .array => |array| try canonicalTypeIsDefaultInitializable(context, path, program, array.item),
                else => false,
            };
        }
        pub fn receiverRefSourceProvenance(
            context: *SemaContext,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            expr: *ast.Expr,
        ) Provenance {
            if (expr.* == .name) {
                if (findLocal(locals, expr.name.text)) |local| {
                    if (local.kind(context) == .ref) return local.provenance;
                }
            }
            return placeRootProvenance(context, "", program, current_module, globals, locals, expr);
        }
        pub fn sourceViewProvenance(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            expr: *ast.Expr,
        ) SemaError!Provenance {
            return (try queryViewSourceBorrowRoots(context, path, program, current_module, globals, locals, expr)).toProvenance();
        }
        pub fn exprProvenanceAs(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            expr: *ast.Expr,
            expected: semantic_types.TypeId,
        ) SemaError!Provenance {
            if (!try typeMayCarryBorrowedProvenance(context, path, program, current_module, expected)) return .none();

            if (isBorrowProducingViewExpr(expr)) {
                return try sourceViewProvenance(context, path, program, current_module, globals, locals, expr);
            }

            return switch (expr.*) {
                .name => |name| blk: {
                    if (findLocal(locals, name.text)) |local| break :blk local.provenance;
                    if (findGlobal(context, program, globals, current_module, name.text)) |global| {
                        break :blk try rootedBorrowProvenanceForType(context, path, program, current_module, global.type_id, .global, global.name);
                    }
                    break :blk .none();
                },
                .address_of => |address_of| placeRootProvenance(context, path, program, current_module, globals, locals, address_of.expr),
                .field => |field| (try exprProvenanceAs(context, path, program, current_module, globals, locals, field.object, expected)).derived(),
                .index => |index| Provenance.combine(
                    (try exprProvenanceAs(context, path, program, current_module, globals, locals, index.object, expected)).derived(),
                    try exprProvenanceAs(context, path, program, current_module, globals, locals, index.index, try canonicalInferredIntegerTypeId(context)),
                ),
                .cast => |cast| try exprProvenanceAs(context, path, program, current_module, globals, locals, cast.subject, expected),
                .@"try" => |try_expr| try exprProvenanceAs(context, path, program, current_module, globals, locals, try_expr.expr, expected),
                .is_test => |is_test| try exprProvenanceAs(context, path, program, current_module, globals, locals, is_test.subject, expected),
                .deref => |deref| try exprProvenanceAs(context, path, program, current_module, globals, locals, deref.expr, expected),
                .slice_range, .method_call => .none(),
                .struct_literal => |literal| try structLiteralProvenance(context, path, program, current_module, globals, locals, literal, expected),
                .new_owned => |literal| try structLiteralProvenance(context, path, program, current_module, globals, locals, literal, expected),
                .array_literal => |literal| blk: {
                    var combined = Provenance.none();
                    const item_type = if (type_resolution.denseStorageLiteralItemType(typeConstructionContext(context), expected)) |dense_item_type|
                        dense_item_type
                    else switch (canonicalTypeNode(context, expected).*) {
                        .array => |array| array.item,
                        else => break :blk .none(),
                    };
                    for (literal.items) |item| {
                        combined = Provenance.combine(combined, try exprProvenanceAs(context, path, program, current_module, globals, locals, item, item_type));
                    }
                    break :blk combined;
                },
                .sequence_repeat => |repeat| blk: {
                    var combined = Provenance.none();
                    const item_type = if (type_resolution.denseStorageLiteralItemType(typeConstructionContext(context), expected)) |dense_item_type|
                        dense_item_type
                    else switch (canonicalTypeNode(context, expected).*) {
                        .array => |array| array.item,
                        else => break :blk .none(),
                    };
                    for (repeat.items) |item| {
                        combined = Provenance.combine(combined, try exprProvenanceAs(context, path, program, current_module, globals, locals, item, item_type));
                    }
                    break :blk combined;
                },
                .typed_sequence_literal => |literal| blk: {
                    const target_type = try parseCanonicalType(context, path, program, current_module, literal.target);
                    var combined = Provenance.none();
                    const item_type = if (type_resolution.denseStorageLiteralItemType(typeConstructionContext(context), target_type)) |dense_item_type|
                        dense_item_type
                    else switch (canonicalTypeNode(context, target_type).*) {
                        .array => |array| array.item,
                        else => break :blk .none(),
                    };
                    for (literal.items) |item| {
                        combined = Provenance.combine(combined, try exprProvenanceAs(context, path, program, current_module, globals, locals, item, item_type));
                    }
                    break :blk combined;
                },
                .fixed_array_construct => |literal| blk: {
                    var combined = Provenance.none();
                    const item_type = canonicalTypeNode(context, expected).array.item;
                    for (literal.items) |item| {
                        combined = Provenance.combine(combined, try exprProvenanceAs(context, path, program, current_module, globals, locals, item, item_type));
                    }
                    break :blk combined;
                },
                .union_case => |case| blk: {
                    const payload = case.value orelse break :blk .none();
                    const payload_type = switch (canonicalTypeNode(context, expected).*) {
                        .optional => |payload_type_id| payload_type_id,
                        .result => |result| result.ok,
                        .nominal => |nominal| blk_payload: {
                            if (nominal.kind != .@"union") break :blk .none();
                            const decl = lookupUnionDeclForType(context, program, expected) orelse break :blk .none();
                            const field = findUnionField(decl.fields, case.case_name) orelse break :blk .none();
                            const payload_name = field.type_name orelse break :blk .none();
                            break :blk_payload try parseCanonicalType(context, path, program, decl.module_name, payload_name);
                        },
                        else => break :blk .none(),
                    };
                    break :blk try exprProvenanceAs(context, path, program, current_module, globals, locals, payload, payload_type);
                },
                else => .none(),
            };
        }
        pub fn structLiteralProvenance(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            globals: []const GlobalBinding,
            locals: []const LocalBinding,
            literal: ast.StructLiteral,
            expected: semantic_types.TypeId,
        ) SemaError!Provenance {
            const layout_type_id: ?semantic_types.TypeId = if (literal.type_name) |explicit_name| blk: {
                const explicit_type = try parseCanonicalType(context, path, program, current_module, .{
                    .is_ref = false,
                    .is_owned = false,
                    .is_raw = false,
                    .is_volatile_raw = false,
                    .is_optional = false,
                    .is_slice = false,
                    .array_len = null,
                    .name = explicit_name,
                    .args = literal.type_args,
                    .token = literal.type_token,
                });
                break :blk if (canonicalTypeKind(context, explicit_type) == .@"struct") explicit_type else null;
            } else blk: {
                var candidate = expected;
                while (true) {
                    candidate = switch (canonicalTypeNode(context, candidate).*) {
                        .ref_ => |reference| reference.target,
                        .owned => |target| target,
                        else => break,
                    };
                }
                break :blk if (canonicalTypeKind(context, candidate) == .@"struct") candidate else null;
            };
            const decl = (if (layout_type_id) |type_id|
                canonicalStructLookup(context, program, type_id)
            else if (literal.type_name) |struct_name|
                lookupStructDecl(context, program, current_module, struct_name)
            else
                null) orelse return .none();
            var combined = Provenance.none();
            switch (decl.fields) {
                .ast_fields => |decl_fields| {
                    for (decl_fields) |decl_field| {
                        const literal_field = findLiteralField(literal.fields, decl_field.name) orelse continue;
                        const field_type = try parseCanonicalType(context, path, program, decl.module_name, decl_field.type_name);
                        combined = Provenance.combine(combined, try exprProvenanceAs(context, path, program, current_module, globals, locals, literal_field.value, field_type));
                    }
                },
                .inst_fields => |decl_fields| {
                    for (decl_fields) |decl_field| {
                        const literal_field = findLiteralField(literal.fields, decl_field.name) orelse continue;
                        combined = Provenance.combine(combined, try exprProvenanceAs(
                            context,
                            path,
                            program,
                            current_module,
                            globals,
                            locals,
                            literal_field.value,
                            decl_field.type_id,
                        ));
                    }
                },
            }
            return combined;
        }
        pub fn propagatedProvenanceForType(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            target: semantic_types.TypeId,
            source: Provenance,
        ) SemaError!Provenance {
            if (!try typeMayCarryBorrowedProvenance(context, path, program, current_module, target)) return .none();
            return source.derived();
        }
        pub fn propagatedProvenanceForTypeId(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            type_id: semantic_types.TypeId,
            source: Provenance,
        ) SemaError!Provenance {
            if (!try typeMayCarryBorrowedProvenance(context, path, program, current_module, type_id)) return .none();
            return source.derived();
        }
        pub fn findAstStructDeclById(context: *SemaContext, program: ast.Program, decl_id: identity.DeclId) ?ast.StructDecl {
            for (program.structs) |decl| {
                if (maybeRegisteredDeclId(context, decl.module_name, null, decl.name, .@"struct") == decl_id) return decl;
            }
            return null;
        }
        pub fn indexHookReturnTypeForType(context: *SemaContext, path: []const u8, program: ast.Program, requester_module: []const u8, type_id: semantic_types.TypeId) SemaError!?semantic_types.TypeId {
            const method = selectSyntaxMethod(context, program, requester_module, type_id, .index) orelse return null;
            return try syntaxMethodReturnType(context, path, program, type_id, method);
        }
        pub fn findKeyedStructEntry(entries: []const ast.KeyedLiteralEntry, name: []const u8) ?ast.KeyedLiteralEntry {
            for (entries) |entry| {
                if (entry.key.* == .name and std.mem.eql(u8, entry.key.name.text, name)) return entry;
            }
            return null;
        }
        pub fn findEnumCase(cases: []const ast.EnumCase, name: []const u8) ?ast.EnumCase {
            for (cases) |case| {
                if (std.mem.eql(u8, case.name, name)) return case;
            }
            return null;
        }
        pub fn findUnionField(fields: []const ast.UnionField, name: []const u8) ?ast.UnionField {
            for (fields) |field| {
                if (std.mem.eql(u8, field.name, name)) return field;
            }
            return null;
        }
        pub fn moduleSourcePath(program: ast.Program, module_name: []const u8, fallback: []const u8) []const u8 {
            for (program.module_infos) |info| {
                if (std.mem.eql(u8, info.name, module_name) and info.source_path.len != 0) return info.source_path;
            }
            return fallback;
        }
        pub fn localSuggestion(locals: []const LocalBinding, name: []const u8) ?[]const u8 {
            var best: ?[]const u8 = null;
            var best_distance: usize = 3;
            var tied = false;
            for (locals) |local| declarations.considerNameSuggestion(name, local.name, &best, &best_distance, &tied);
            return if (tied) null else best;
        }
        pub fn callableSuggestion(context: *const SemaContext, program: ast.Program, current_module: []const u8, name: []const u8) ?[]const u8 {
            var best: ?[]const u8 = null;
            var best_distance: usize = 3;
            var tied = false;
            for (program.functions) |function| {
                if (function.owner != null) continue;
                if (!canAccessDecl(context, current_module, function.module_name, function.is_pub)) continue;
                declarations.considerNameSuggestion(name, function.name, &best, &best_distance, &tied);
            }
            return if (tied) null else best;
        }
        pub fn emitUnknownValue(
            context: *SemaContext,
            path: []const u8,
            token: lexer.Token,
            locals: []const LocalBinding,
            name: []const u8,
            kind: UnknownValueKind,
        ) SemaError!void {
            const suggestion = localSuggestion(locals, name);
            const help = if (suggestion) |candidate|
                try std.fmt.allocPrint(context.allocator, "did you mean `{s}`?", .{candidate})
            else
                null;
            defer if (help) |text| context.allocator.free(text);
            const notes = [_][]const u8{"value lookup searches the active lexical scopes"};
            switch (kind) {
                .value => try context.diagnostic_context.emitTokenWith(path, token, .{
                    .code = .name_unknown_value,
                    .notes = &notes,
                    .help = help,
                }, "unknown value `{s}`", .{name}),
                .local => try context.diagnostic_context.emitTokenWith(path, token, .{
                    .code = .name_unknown_value,
                    .notes = &notes,
                    .help = help,
                }, "unknown local `{s}`", .{name}),
                .binding => try context.diagnostic_context.emitTokenWith(path, token, .{
                    .code = .name_unknown_value,
                    .notes = &notes,
                    .help = help,
                }, "unknown binding `{s}`", .{name}),
            }
        }
        pub fn emitUnknownCallable(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            token: lexer.Token,
            name: []const u8,
        ) SemaError!void {
            const suggestion = callableSuggestion(context, program, current_module, name);
            const help = if (suggestion) |candidate|
                try std.fmt.allocPrint(context.allocator, "did you mean `{s}`?", .{candidate})
            else
                "declare the function or import it into this scope";
            defer if (suggestion != null) context.allocator.free(help);
            const notes = [_][]const u8{"callable lookup is distinct from type and value lookup"};
            try context.diagnostic_context.emitTokenWith(path, token, .{
                .code = .name_unknown_callable,
                .notes = &notes,
                .help = help,
            }, "unknown function `{s}`", .{name});
        }
        pub fn withIntrinsic(typed: TypedExpr, intrinsic_id: sir.IntrinsicId) TypedExpr {
            var result = typed;
            result.intrinsic_id = intrinsic_id;
            return result;
        }
        pub fn makeTypedExpr(context: *SemaContext, expr: *sir.Expr, ty: anytype) SemaError!TypedExpr {
            return makeTypedExprWithProvenance(context, expr, ty, .none());
        }
        pub fn makeTypedExprFromIdWithProvenance(expr: *sir.Expr, type_id: semantic_types.TypeId, provenance: Provenance) TypedExpr {
            return .{
                .expr = expr,
                .type_id = type_id,
                .provenance = provenance,
            };
        }
        pub fn makeTypedExprFromIdWithProvenanceAndValueSemantics(expr: *sir.Expr, type_id: semantic_types.TypeId, provenance: Provenance, semantics: sir.ValueSemantics) TypedExpr {
            var typed = makeTypedExprFromIdWithProvenance(expr, type_id, provenance);
            typed.value_semantics = semantics;
            return typed;
        }
        pub fn makeTypedExprWithProvenance(_: *SemaContext, expr: *sir.Expr, type_id: semantic_types.TypeId, provenance: Provenance) SemaError!TypedExpr {
            return .{
                .expr = expr,
                .type_id = type_id,
                .provenance = provenance,
            };
        }
        pub fn makeTypedExprWithProvenanceAndValueSemantics(context: *SemaContext, expr: *sir.Expr, type_id: semantic_types.TypeId, provenance: Provenance, semantics: sir.ValueSemantics) SemaError!TypedExpr {
            var typed = try makeTypedExprWithProvenance(context, expr, type_id, provenance);
            typed.value_semantics = semantics;
            return typed;
        }
        pub fn typeStructField(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            ty: semantic_types.TypeId,
            field_name: []const u8,
            field_token: lexer.Token,
        ) SemaError!StructFieldAccess {
            if (canonicalTypeNode(context, ty).* == .tuple) return SemaError.SemanticFailed;
            if (canonicalTypeKind(context, ty) != .@"struct") {
                try context.diagnostic_context.emitToken(path, field_token, "field access requires a struct value", .{});
                return SemaError.SemanticFailed;
            }
            const struct_name = canonicalNominalDeclName(context, program, ty) orelse {
                try context.diagnostic_context.emitToken(path, field_token, "field access requires a named struct value", .{});
                return SemaError.SemanticFailed;
            };
            const decl = canonicalStructLookup(context, program, ty) orelse {
                try context.diagnostic_context.emitToken(path, field_token, "unknown struct `{s}`", .{struct_name});
                return SemaError.SemanticFailed;
            };
            const struct_decl_id = canonicalNominalDeclId(context, ty) orelse try registeredDeclId(context, decl.module_name, null, struct_name, .@"struct");
            const decl_field = lookupStructField(decl, field_name) orelse {
                try context.diagnostic_context.emitToken(path, field_token, "struct `{s}` has no field `{s}`", .{ struct_name, field_name });
                return SemaError.SemanticFailed;
            };
            if (!canAccessDecl(context, current_module, decl.module_name, decl_field.is_pub)) {
                try context.diagnostic_context.emitToken(path, field_token, "field `{s}` of struct `{s}` is not public", .{ field_name, struct_name });
                return SemaError.SemanticFailed;
            }
            return .{
                .struct_decl_id = struct_decl_id,
                .struct_name = struct_name,
                .decl = decl,
                .decl_field = decl_field,
                .field_type_id = try structFieldTypeId(context, path, program, decl, decl_field),
            };
        }
        pub fn typeUnionPayloadField(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            current_module: []const u8,
            ty: semantic_types.TypeId,
            field_name: []const u8,
            field_token: lexer.Token,
        ) SemaError!UnionPayloadAccess {
            _ = current_module;
            if (canonicalTypeKind(context, ty) != .@"union") {
                try context.diagnostic_context.emitToken(path, field_token, "field access requires a union value", .{});
                return SemaError.SemanticFailed;
            }
            const union_name = canonicalNominalDeclName(context, program, ty) orelse {
                try context.diagnostic_context.emitToken(path, field_token, "field access requires a named union value", .{});
                return SemaError.SemanticFailed;
            };
            const union_decl_id = canonicalNominalDeclId(context, ty) orelse return error.SemanticFailed;
            const decl = lookupUnionDeclById(context, program, union_decl_id) orelse {
                try context.diagnostic_context.emitToken(path, field_token, "unknown union `{s}`", .{union_name});
                return SemaError.SemanticFailed;
            };
            const union_field = findUnionField(decl.fields, field_name) orelse {
                try context.diagnostic_context.emitToken(path, field_token, "union `{s}` has no case `{s}`", .{ union_name, field_name });
                return SemaError.SemanticFailed;
            };
            const type_name = union_field.type_name orelse {
                try context.diagnostic_context.emitToken(path, field_token, "union case `{s}.{s}` does not carry a payload", .{ union_name, field_name });
                return SemaError.SemanticFailed;
            };
            return .{
                .union_decl_id = union_decl_id,
                .union_name = union_name,
                .field_type_id = try parseCanonicalType(context, path, program, decl.module_name, type_name),
            };
        }
        pub fn recordArrowCapture(allocator: std.mem.Allocator, records: *std.ArrayListUnmanaged(LocalBinding), captured: LocalBinding) SemaError!u32 {
            if (findLocalIndex(records.items, captured.name)) |index| return @intCast(index);
            try records.append(allocator, captured);
            return @intCast(records.items.len - 1);
        }
        pub fn localBinding(context: *SemaContext, name: []const u8, type_id: semantic_types.TypeId, is_param: bool, is_mutable: bool) SemaError!LocalBinding {
            return .{
                .name = name,
                .binding_id = try nextBindingId(context),
                .borrowed_place = .none(),
                .provenance = .none(),
                .type_id = type_id,
                .is_param = is_param,
                .is_mutable = is_mutable,
                .is_for_binding = false,
                .is_unavailable = false,
                .projection_origin = null,
                .is_scoped_alloc_value = false,
                .scoped_alloc_origin = null,
                .scope_depth = context.function_state.block_depth,
            };
        }
        pub fn internCanonicalNode(interner: *semantic_types.TypeInterner, node: semantic_types.Type) SemaError!semantic_types.TypeId {
            return type_resolution.internNode(interner, node);
        }
        pub fn parseTypeWithSelf(context: *SemaContext, path: []const u8, program: ast.Program, current_module: []const u8, type_name: ast.TypeName, self_type: ?semantic_types.TypeId) SemaError!semantic_types.TypeId {
            return parseTypeWithBindings(context, path, program, current_module, type_name, self_type, context.function_state.current_generic_params, context.function_state.current_generic_args);
        }
        pub fn typeLookupModule(context: *SemaContext, path: []const u8, program: ast.Program, current_module: []const u8, type_name: ast.TypeName) SemaError!?[]const u8 {
            return type_resolution.lookupModule(canonical.sourceContext(context), path, program, current_module, type_name);
        }
        /// One entry point for the return type published by a declaration.
        /// Errorful `T!` resolution will live here so body, call and callable
        /// signatures cannot independently choose different error sets.
        pub fn resolvedFunctionReturnType(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            function: ast.Function,
            params: []const ast.GenericParam,
            args: []const semantic_types.GenericArgument,
        ) SemaError!semantic_types.TypeId {
            const type_name = function.return_type orelse return canonicalPrimitiveTypeId(context, .void);
            if (!type_name.is_inferred_result_return)
                return parseTypeWithBindings(context, path, program, function.module_name, type_name, null, params, args);

            // A source declaration has one stable cycle key. Only non-generic
            // declarations keep a resolved value: generic return types depend on
            // active bindings and concrete calls publish checked SIR types.
            const key = maybeRegisteredDeclId(context, function.module_name, function.owner, function.name, .function);
            const cacheable = function.type_params.len == 0;
            if (key) |id| {
                if (context.return_resolutions.get(id)) |cached| return switch (cached) {
                    .resolved => |resolved| resolved,
                    .in_progress => {
                        try context.diagnostic_context.emitToken(path, type_name.token, "recursive `T!` error inference requires an explicit error type", .{});
                        return SemaError.SemanticFailed;
                    },
                };
                try context.return_resolutions.put(context.allocator, id, .in_progress);
            }
            var keep_cache = false;
            defer {
                if (!keep_cache) {
                    if (key) |id| _ = context.return_resolutions.remove(id);
                }
            }

            const success = try parseTypeWithBindings(context, path, program, function.module_name, type_name, null, params, args);
            var errors: std.ArrayListUnmanaged(semantic_types.TypeId) = .empty;
            defer errors.deinit(context.allocator);
            var locals: std.ArrayListUnmanaged(InferredLocalType) = .empty;
            defer locals.deinit(context.allocator);
            _ = try collectInferredErrorsInStatements(context, path, program, function, params, args, function.body, &locals, &errors);
            const resolved = if (errors.items.len == 0) success else try canonicalResultTypeId(context, success, try inferredResultErrorType(context, path, program, type_name.token, errors.items));
            if (cacheable) if (key) |id| {
                context.return_resolutions.getPtr(id).?.* = .{ .resolved = resolved };
                keep_cache = true;
            };
            return resolved;
        }

        fn appendInferredError(context: *SemaContext, errors: *std.ArrayListUnmanaged(semantic_types.TypeId), error_type: semantic_types.TypeId) SemaError!void {
            for (errors.items) |existing| if (existing == error_type) return;
            try errors.append(context.allocator, error_type);
        }

        fn inferredResultErrorType(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            token: lexer.Token,
            errors: []const semantic_types.TypeId,
        ) SemaError!semantic_types.TypeId {
            var union_type: ?semantic_types.TypeId = null;
            var members: std.ArrayListUnmanaged(semantic_types.TypeId) = .empty;
            defer members.deinit(context.allocator);
            for (errors) |error_type| {
                if (canonicalTypeKind(context, error_type) == .@"enum") {
                    try appendInferredError(context, &members, error_type);
                    continue;
                }
                if (union_type == null) union_type = error_type;
                const union_members = try inferredErrorUnionMembers(context, path, program, error_type);
                defer context.allocator.free(union_members);
                for (union_members) |member| try appendInferredError(context, &members, member);
            }
            if (union_type) |target| {
                for (errors) |error_type| {
                    if (error_type == target) continue;
                    if (canonicalTypeKind(context, error_type) == .@"enum" and
                        try tryErrorWidenOrdinal(context, path, program, target, error_type, token) != null) continue;
                    if (canonicalTypeKind(context, error_type) == .@"union" and
                        try tryErrorUnionWidenAllowed(context, path, program, target, error_type)) continue;
                    return canonical.errorUnionType(context, members.items);
                }
                return target;
            }
            return if (errors.len == 1) errors[0] else try canonical.errorUnionType(context, errors);
        }

        fn inferredErrorUnionMembers(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            error_type: semantic_types.TypeId,
        ) SemaError![]semantic_types.TypeId {
            if (canonicalTypeNode(context, error_type).* == .error_union)
                return context.allocator.dupe(semantic_types.TypeId, canonicalTypeNode(context, error_type).error_union);
            const decl_id = canonicalNominalDeclId(context, error_type) orelse return error.SemanticFailed;
            const decl = lookupUnionDeclById(context, program, decl_id) orelse return error.SemanticFailed;
            if (decl.kind != .type_union) return error.SemanticFailed;
            const members = try context.allocator.alloc(semantic_types.TypeId, decl.variants.len);
            errdefer context.allocator.free(members);
            for (decl.variants, members) |variant, *member|
                member.* = try parseCanonicalType(context, path, program, decl.module_name, variant);
            return members;
        }

        fn tryErrorUnionWidenAllowed(context: *SemaContext, path: []const u8, program: ast.Program, target: semantic_types.TypeId, source: semantic_types.TypeId) SemaError!bool {
            if (canonicalTypeKind(context, target) != .@"union" or canonicalTypeKind(context, source) != .@"union") return false;
            const target_members = try inferredErrorUnionMembers(context, path, program, target);
            defer context.allocator.free(target_members);
            const source_members = try inferredErrorUnionMembers(context, path, program, source);
            defer context.allocator.free(source_members);
            for (source_members) |member| {
                var found = false;
                for (target_members) |candidate| {
                    if (candidate == member) {
                        found = true;
                        break;
                    }
                }
                if (!found) return false;
            }
            return true;
        }

        const InferredLocalType = struct { name: []const u8, type_id: ?semantic_types.TypeId };

        /// Returns true when this statement list cannot reach a following one.
        fn collectInferredErrorsInStatements(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            function: ast.Function,
            params: []const ast.GenericParam,
            args: []const semantic_types.GenericArgument,
            statements: []const ast.Stmt,
            locals: *std.ArrayListUnmanaged(InferredLocalType),
            errors: *std.ArrayListUnmanaged(semantic_types.TypeId),
        ) SemaError!bool {
            const scope_start = locals.items.len;
            defer locals.shrinkRetainingCapacity(scope_start);
            for (statements) |stmt| switch (stmt) {
                .@"return" => |ret| {
                    if (ret.is_throw) {
                        const code = ret.value.?.union_case.value orelse return error.SemanticFailed;
                        if (code.* != .enum_case) {
                            try context.diagnostic_context.emitToken(path, ret.token, "inferred `T!` throw requires a qualified `Enum.case` error", .{});
                            return SemaError.SemanticFailed;
                        }
                        const error_name = ast.TypeName{ .name = code.enum_case.type_name, .args = &.{}, .token = code.enum_case.token };
                        const error_type = try parseTypeWithBindings(context, path, program, function.module_name, error_name, null, params, args);
                        if (canonicalTypeKind(context, error_type) != .@"enum") {
                            try context.diagnostic_context.emitToken(path, ret.token, "inferred `T!` throw requires an error enum", .{});
                            return SemaError.SemanticFailed;
                        }
                        try appendInferredError(context, errors, error_type);
                    } else if (ret.value) |value| {
                        try collectInferredErrorsInExpr(context, path, program, function, params, args, locals.items, value, errors);
                    }
                    return true;
                },
                .@"try" => |value| {
                    try collectInferredErrorsInExpr(context, path, program, function, params, args, locals.items, value, errors);
                    try collectDirectTryError(context, path, program, function, params, args, locals.items, value, ast.firstExprToken(value), errors);
                },
                .local => |local| {
                    try collectInferredErrorsInExpr(context, path, program, function, params, args, locals.items, local.init, errors);
                    const type_id = if (local.type_name) |type_name|
                        try parseTypeWithBindings(context, path, program, function.module_name, type_name, null, params, args)
                    else
                        try inferredDirectCallType(context, path, program, function, params, args, locals.items, local.init);
                    try locals.append(context.allocator, .{ .name = local.name, .type_id = type_id });
                },
                .discard => |value| try collectInferredErrorsInExpr(context, path, program, function, params, args, locals.items, value, errors),
                .expr => |value| try collectInferredErrorsInExpr(context, path, program, function, params, args, locals.items, value, errors),
                .assign => |value| try collectInferredErrorsInExpr(context, path, program, function, params, args, locals.items, value.value, errors),
                .field_assign => |value| {
                    try collectInferredErrorsInExpr(context, path, program, function, params, args, locals.items, value.object, errors);
                    try collectInferredErrorsInExpr(context, path, program, function, params, args, locals.items, value.value, errors);
                },
                .index_assign => |value| {
                    try collectInferredErrorsInExpr(context, path, program, function, params, args, locals.items, value.object, errors);
                    try collectInferredErrorsInExpr(context, path, program, function, params, args, locals.items, value.index, errors);
                    try collectInferredErrorsInExpr(context, path, program, function, params, args, locals.items, value.value, errors);
                },
                .deref_assign => |value| {
                    try collectInferredErrorsInExpr(context, path, program, function, params, args, locals.items, value.pointer, errors);
                    try collectInferredErrorsInExpr(context, path, program, function, params, args, locals.items, value.value, errors);
                },
                .deref_field_assign => |value| {
                    try collectInferredErrorsInExpr(context, path, program, function, params, args, locals.items, value.pointer, errors);
                    try collectInferredErrorsInExpr(context, path, program, function, params, args, locals.items, value.value, errors);
                },
                .yield => |value| if (value.value) |expr| try collectInferredErrorsInExpr(context, path, program, function, params, args, locals.items, expr, errors),
                .@"defer" => |value| try collectInferredErrorsInExpr(context, path, program, function, params, args, locals.items, value, errors),
                .asm_stmt => |asm_stmt| for (asm_stmt.inputs) |input| try collectInferredErrorsInExpr(context, path, program, function, params, args, locals.items, input.value, errors),
                .@"if" => |branch| {
                    try collectInferredErrorsInExpr(context, path, program, function, params, args, locals.items, branch.condition, errors);
                    const then_terminal = try collectInferredErrorsInStatements(context, path, program, function, params, args, branch.then_body, locals, errors);
                    const else_terminal = try collectInferredErrorsInStatements(context, path, program, function, params, args, branch.else_body, locals, errors);
                    if (then_terminal and else_terminal) return true;
                },
                .@"switch" => |branch| {
                    try collectInferredErrorsInExpr(context, path, program, function, params, args, locals.items, branch.value, errors);
                    var terminal = branch.has_else;
                    for (branch.cases) |case| {
                        if (!try collectInferredErrorsInStatements(context, path, program, function, params, args, case.body, locals, errors)) terminal = false;
                    }
                    if (branch.has_else and !try collectInferredErrorsInStatements(context, path, program, function, params, args, branch.else_body, locals, errors)) terminal = false;
                    if (terminal) return true;
                },
                .@"while" => |loop| {
                    try collectInferredErrorsInExpr(context, path, program, function, params, args, locals.items, loop.condition, errors);
                    _ = try collectInferredErrorsInStatements(context, path, program, function, params, args, loop.body, locals, errors);
                },
                .@"for" => |loop| {
                    try collectInferredErrorsInExpr(context, path, program, function, params, args, locals.items, loop.iterable, errors);
                    _ = try collectInferredErrorsInStatements(context, path, program, function, params, args, loop.body, locals, errors);
                },
                .unchecked => |body| if (try collectInferredErrorsInStatements(context, path, program, function, params, args, body, locals, errors)) return true,
                .using_alloc => |block| {
                    try collectInferredErrorsInExpr(context, path, program, function, params, args, locals.items, block.allocator_expr, errors);
                    if (try collectInferredErrorsInStatements(context, path, program, function, params, args, block.body, locals, errors)) return true;
                },
                else => {},
            };
            return false;
        }

        fn collectInferredErrorsInExpr(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            function: ast.Function,
            params: []const ast.GenericParam,
            args: []const semantic_types.GenericArgument,
            locals: []const InferredLocalType,
            expr: *ast.Expr,
            errors: *std.ArrayListUnmanaged(semantic_types.TypeId),
        ) SemaError!void {
            switch (expr.*) {
                .@"try" => |value| {
                    try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, value.expr, errors);
                    try collectDirectTryError(context, path, program, function, params, args, locals, value.expr, value.token, errors);
                },
                .binary => |value| {
                    try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, value.left, errors);
                    try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, value.right, errors);
                },
                .unary => |value| try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, value.expr, errors),
                .deref => |value| try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, value.expr, errors),
                .address_of => |value| try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, value.expr, errors),
                .cast => |value| try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, value.subject, errors),
                .is_test => |value| try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, value.subject, errors),
                .@"comptime" => |value| try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, value.expr, errors),
                .call => |call| for (call.args) |arg| switch (arg) {
                    .value => |value| try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, value, errors),
                },
                .method_call => |call| {
                    try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, call.object, errors);
                    for (call.args) |arg| switch (arg) {
                        .value => |value| try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, value, errors),
                    };
                },
                .@"switch" => |branch| {
                    try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, branch.value, errors);
                    for (branch.cases) |outer_case| {
                        if (!std.mem.eql(u8, outer_case.case_name, "err") or outer_case.body.len != 1 or outer_case.body[0] != .yield) continue;
                        const arm_expr = outer_case.body[0].yield.value orelse continue;
                        if (arm_expr.* != .@"switch" or !arm_expr.@"switch".catch_propagate_unmatched) continue;
                        const handler = arm_expr.@"switch";
                        const source_type = (try inferredDirectCallType(context, path, program, function, params, args, locals, branch.value)) orelse blk: {
                            if (branch.value.* == .name) {
                                const name = branch.value.name.text;
                                var index = locals.len;
                                while (index > 0) {
                                    index -= 1;
                                    if (std.mem.eql(u8, locals[index].name, name)) break :blk locals[index].type_id;
                                }
                                for (function.params) |param| if (std.mem.eql(u8, param.name, name)) {
                                    break :blk try parseTypeWithBindings(context, path, program, function.module_name, param.type_name, null, params, args);
                                };
                            }
                            break :blk null;
                        } orelse {
                            try context.diagnostic_context.emitToken(path, ast.firstExprToken(branch.value), "cannot infer partial `catch` errors from this result expression; declare an explicit error type", .{});
                            return error.SemanticFailed;
                        };
                        const source_node = canonicalTypeNode(context, source_type);
                        if (source_node.* != .result) return error.SemanticFailed;
                        const error_type = source_node.result.err;
                        if (canonicalTypeKind(context, error_type) == .@"enum") {
                            const enum_id = canonicalNominalDeclId(context, error_type) orelse return error.SemanticFailed;
                            const enum_decl = lookupEnumDeclById(context, program, enum_id) orelse return error.SemanticFailed;
                            for (enum_decl.cases) |case| {
                                if (!switchCoversCase(handler.cases, enum_decl.name, case.name)) {
                                    try appendInferredError(context, errors, error_type);
                                    break;
                                }
                            }
                        } else {
                            const members = try inferredErrorUnionMembers(context, path, program, error_type);
                            defer context.allocator.free(members);
                            for (members) |member| {
                                var covered = false;
                                for (handler.cases) |case| if (case.type_variant) |variant| {
                                    if (try parseTypeWithBindings(context, path, program, function.module_name, variant, null, params, args) == member) covered = true;
                                };
                                if (!covered) try appendInferredError(context, errors, member);
                            }
                        }
                    }
                    var scoped_locals: std.ArrayListUnmanaged(InferredLocalType) = .empty;
                    defer scoped_locals.deinit(context.allocator);
                    for (branch.cases) |case| {
                        scoped_locals.clearRetainingCapacity();
                        try scoped_locals.appendSlice(context.allocator, locals);
                        _ = try collectInferredErrorsInStatements(context, path, program, function, params, args, case.body, &scoped_locals, errors);
                    }
                    if (branch.has_else) {
                        scoped_locals.clearRetainingCapacity();
                        try scoped_locals.appendSlice(context.allocator, locals);
                        _ = try collectInferredErrorsInStatements(context, path, program, function, params, args, branch.else_body, &scoped_locals, errors);
                    }
                },
                .union_case => |value| if (value.value) |payload| try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, payload, errors),
                .field => |value| try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, value.object, errors),
                .index => |value| {
                    try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, value.object, errors);
                    try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, value.index, errors);
                },
                .slice_range => |value| {
                    try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, value.object, errors);
                    if (value.start) |start| try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, start, errors);
                    if (value.end) |end| try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, end, errors);
                },
                .array_literal => |value| for (value.items) |item| try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, item, errors),
                .typed_sequence_literal => |value| for (value.items) |item| try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, item, errors),
                .fixed_array_construct => |value| for (value.items) |item| try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, item, errors),
                .sequence_repeat => |value| {
                    for (value.items) |item| try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, item, errors);
                    try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, value.count, errors);
                },
                .keyed_literal => |value| for (value.entries) |entry| {
                    try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, entry.key, errors);
                    try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, entry.value, errors);
                },
                .new_array => |value| try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, value.len, errors),
                .new_sparse => |value| try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, value.capacity, errors),
                .new_owned, .struct_literal => |value| for (value.fields) |field| try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, field.value, errors),
                .asm_expr => |asm_expr| {
                    if (asm_expr.inout) |input| try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, input.value, errors);
                    for (asm_expr.inputs) |input| try collectInferredErrorsInExpr(context, path, program, function, params, args, locals, input.value, errors);
                },
                else => {},
            }
        }

        fn inferredDirectCallType(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            function: ast.Function,
            params: []const ast.GenericParam,
            args: []const semantic_types.GenericArgument,
            locals: []const InferredLocalType,
            expr: *ast.Expr,
        ) SemaError!?semantic_types.TypeId {
            if (expr.* != .call or expr.call.owner != null) return null;
            const call = expr.call;
            const callee = (try resolveAstFunction(context, program, function.module_name, call.owner, call.callee)) orelse return null;
            if (callee.decl.type_params.len == 0) return try resolvedFunctionReturnType(context, path, program, callee.decl, &.{}, &.{});
            const resolved_args = if (call.type_args.len != 0) blk: {
                if (call.type_args.len != callee.decl.type_params.len) return null;
                const explicit = try context.allocator.alloc(semantic_types.GenericArgument, call.type_args.len);
                errdefer context.allocator.free(explicit);
                for (call.type_args, callee.decl.type_params, 0..) |arg, param, i| {
                    explicit[i] = try resolveGenericArgument(context, path, program, function.module_name, arg, param, null, params, args, 0);
                }
                break :blk explicit;
            } else blk: {
                if (call.args.len != callee.decl.params.len) return null;
                const actual = try context.allocator.alloc(struct { type_id: semantic_types.TypeId }, call.args.len);
                defer context.allocator.free(actual);
                for (call.args, actual) |arg, *slot| {
                    slot.type_id = (try inferredAstArgumentType(context, path, program, function, params, args, locals, arg.value)) orelse return null;
                }
                break :blk try inferGenericArgsFromCall(context, path, program, function.module_name, callee.decl, actual, null);
            };
            defer context.allocator.free(resolved_args);
            return try resolvedFunctionReturnType(context, path, program, callee.decl, callee.decl.type_params, resolved_args);
        }

        fn inferredAstArgumentType(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            function: ast.Function,
            params: []const ast.GenericParam,
            args: []const semantic_types.GenericArgument,
            locals: []const InferredLocalType,
            expr: *ast.Expr,
        ) SemaError!?semantic_types.TypeId {
            return switch (expr.*) {
                .int => try canonicalInferredIntegerTypeId(context),
                .bool => try canonicalPrimitiveTypeId(context, .bool),
                .string => try canonicalPrimitiveTypeId(context, .string),
                .float => try canonicalFloatTypeId(context, "f64"),
                .cast => |cast| if (cast.fallible) null else try parseTypeWithBindings(context, path, program, function.module_name, cast.target, null, params, args),
                .name => |name| blk: {
                    var i = locals.len;
                    while (i > 0) {
                        i -= 1;
                        if (std.mem.eql(u8, locals[i].name, name.text)) break :blk locals[i].type_id;
                    }
                    for (function.params) |param| {
                        if (std.mem.eql(u8, param.name, name.text))
                            break :blk try parseTypeWithBindings(context, path, program, function.module_name, param.type_name, null, params, args);
                    }
                    break :blk null;
                },
                .call => try inferredDirectCallType(context, path, program, function, params, args, locals, expr),
                else => null,
            };
        }

        fn collectDirectTryError(
            context: *SemaContext,
            path: []const u8,
            program: ast.Program,
            function: ast.Function,
            params: []const ast.GenericParam,
            args: []const semantic_types.GenericArgument,
            locals: []const InferredLocalType,
            operand: *ast.Expr,
            token: lexer.Token,
            errors: *std.ArrayListUnmanaged(semantic_types.TypeId),
        ) SemaError!void {
            if (operand.* == .name) {
                const name = operand.name.text;
                var i = locals.len;
                while (i > 0) {
                    i -= 1;
                    if (!std.mem.eql(u8, locals[i].name, name)) continue;
                    if (locals[i].type_id) |type_id| {
                        const node = canonicalTypeNode(context, type_id);
                        if (node.* == .result and (canonicalTypeKind(context, node.result.err) == .@"enum" or canonicalTypeKind(context, node.result.err) == .@"union")) {
                            try appendInferredError(context, errors, node.result.err);
                            return;
                        }
                    }
                    try context.diagnostic_context.emitToken(path, token, "cannot infer `T!` error type from this `try` operand; declare an explicit error type", .{});
                    return SemaError.SemanticFailed;
                }
                for (function.params) |param| {
                    if (!std.mem.eql(u8, param.name, name)) continue;
                    const result_type = try parseTypeWithBindings(context, path, program, function.module_name, param.type_name, null, params, args);
                    const node = canonicalTypeNode(context, result_type);
                    if (node.* != .result or (canonicalTypeKind(context, node.result.err) != .@"enum" and canonicalTypeKind(context, node.result.err) != .@"union")) break;
                    try appendInferredError(context, errors, node.result.err);
                    return;
                }
                try context.diagnostic_context.emitToken(path, token, "cannot infer `T!` error type from this `try` operand; declare an explicit error type", .{});
                return SemaError.SemanticFailed;
            }
            if (operand.* != .call or operand.call.owner != null) {
                try context.diagnostic_context.emitToken(path, token, "cannot infer `T!` error type from this `try` operand; declare an explicit error type", .{});
                return SemaError.SemanticFailed;
            }
            const result_type = (try inferredDirectCallType(context, path, program, function, params, args, locals, operand)) orelse {
                try context.diagnostic_context.emitToken(path, token, "cannot infer `T!` error type from this `try` operand; declare an explicit error type", .{});
                return SemaError.SemanticFailed;
            };
            const node = canonicalTypeNode(context, result_type);
            if (node.* != .result or (canonicalTypeKind(context, node.result.err) != .@"enum" and canonicalTypeKind(context, node.result.err) != .@"union")) {
                try context.diagnostic_context.emitToken(path, token, "inferred `T!` currently requires a `try` callee with an enum or enum-union error type", .{});
                return SemaError.SemanticFailed;
            }
            try appendInferredError(context, errors, node.result.err);
        }

        pub fn functionDeclType(
            context: *SemaContext,
            allocator: std.mem.Allocator,
            path: []const u8,
            program: ast.Program,
            function: ast.Function,
        ) SemaError!semantic_types.TypeId {
            const params = try allocator.alloc(semantic_types.TypeId, function.params.len);
            defer allocator.free(params);
            for (function.params, 0..) |param, i| {
                params[i] = try parseTypeWithBindings(context, path, program, function.module_name, param.type_name, null, &.{}, &.{});
            }
            const return_type = try resolvedFunctionReturnType(context, path, program, function, &.{}, &.{});
            const signature = try formatFunctionTypeSignature(context, function.calling_convention, params, return_type);
            context.output.generated_strings.append(context.allocator, signature) catch |err| {
                context.allocator.free(signature);
                return err;
            };
            return internCallableType(
                context,
                .function,
                if (function.calling_convention == .c) .c else .cyna,
                params,
                return_type,
            );
        }
        pub fn intLiteralFitsType(context: *SemaContext, value: i64, unsigned_value: ?u64, type_name: []const u8) bool {
            if (std.mem.eql(u8, type_name, "c_size_t") or std.mem.eql(u8, type_name, "usize")) {
                return intLiteralFitsUnsignedBits(value, unsigned_value, context.abi_layout.ptr_bits);
            }
            if (isCAbiScalarTypeName(type_name)) return true;
            if (std.mem.eql(u8, type_name, "isize")) return unsigned_value == null;
            if (type_name.len < 2) return false;
            const signed = type_name[0] == 'i';
            const unsigned = type_name[0] == 'u';
            if (!signed and !unsigned) return false;
            const bits = std.fmt.parseInt(u8, type_name[1..], 10) catch return false;
            if (bits == 0 or bits > 64) return false;
            if (unsigned) {
                return intLiteralFitsUnsignedBits(value, unsigned_value, bits);
            }
            if (unsigned_value != null) return false;
            if (bits == 64) return true;
            const shift: u6 = @intCast(bits - 1);
            const min: i64 = -(@as(i64, 1) << shift);
            const max: i64 = (@as(i64, 1) << shift) - 1;
            return value >= min and value <= max;
        }
        pub fn intLiteralFitsUnsignedBits(value: i64, unsigned_value: ?u64, bits: u16) bool {
            if (bits == 0 or bits > 64) return false;
            const magnitude: u64 = if (unsigned_value) |wide| wide else blk: {
                if (value < 0) return false;
                break :blk @intCast(value);
            };
            if (bits == 64) return true;
            const max = (@as(u64, 1) << @as(u6, @intCast(bits))) - 1;
            return magnitude <= max;
        }
        pub fn packedStructBitWidth(context: *SemaContext, program: ast.Program, type_id: semantic_types.TypeId) SemaError!?u16 {
            const decl = canonicalStructLookup(context, program, type_id) orelse return null;
            if (decl.layout != .@"packed") return null;
            var total: u32 = 0;
            switch (decl.fields) {
                .ast_fields => |fields| for (fields) |field| {
                    const field_ty = try parseType(context, "", program, decl.module_name, field.type_name);
                    total += try packedTypeBitWidth(context, program, field_ty);
                },
                .inst_fields => |fields| for (fields) |field| {
                    total += try packedTypeBitWidth(context, program, field.type_id);
                },
            }
            if (total > std.math.maxInt(u16)) return null;
            return @intCast(total);
        }
        pub fn packedTypeBitWidth(context: *SemaContext, program: ast.Program, type_id: semantic_types.TypeId) SemaError!u32 {
            return switch (canonicalTypeNode(context, type_id).*) {
                .inferred_integer => 64,
                .integer => |integer| integer.bits,
                .nominal => |nominal| switch (nominal.kind) {
                    .@"enum" => blk: {
                        const decl = lookupEnumDeclById(context, program, nominal.decl_id) orelse return SemaError.SemanticFailed;
                        const repr_name = decl.repr_name orelse return SemaError.SemanticFailed;
                        const repr_type = try canonicalIntegerTypeId(context, repr_name);
                        break :blk try packedTypeBitWidth(context, program, repr_type);
                    },
                    .@"struct" => (try packedStructBitWidth(context, program, type_id)) orelse return SemaError.SemanticFailed,
                    .type_alias => if (nominal.underlying) |underlying|
                        try packedTypeBitWidth(context, program, underlying)
                    else
                        SemaError.SemanticFailed,
                    else => SemaError.SemanticFailed,
                },
                .generic_instance => |instance| switch (instance.kind) {
                    .@"struct" => (try packedStructBitWidth(context, program, type_id)) orelse return SemaError.SemanticFailed,
                    else => SemaError.SemanticFailed,
                },
                else => SemaError.SemanticFailed,
            };
        }
        pub fn typeEqual(_: *SemaContext, a: semantic_types.TypeId, b: semantic_types.TypeId) bool {
            return a == b;
        }
        pub fn typeHasStorageLifetime(context: *SemaContext, path: []const u8, program: ast.Program, type_id: semantic_types.TypeId) SemaError!bool {
            return canonicalTypeHasStorageLifetime(context, path, program, type_id);
        }
        pub fn typeIsDefaultInitializable(context: *SemaContext, path: []const u8, program: ast.Program, type_id: semantic_types.TypeId) SemaError!bool {
            return canonicalTypeIsDefaultInitializable(context, path, program, type_id);
        }
    };
}

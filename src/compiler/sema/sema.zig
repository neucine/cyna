const std = @import("std");
const ast = @import("../parser/ast.zig");
const build_model = @import("../../build/model.zig");
const callable_analysis = ownership_owner.callables;
const sir_finalization = @import("sir_finalization.zig");
const sir = @import("sir.zig");
const effects = @import("effects.zig");
const concurrency = @import("concurrency.zig");
const generated_names = @import("../generated_names.zig");
const diagnostics = @import("../diagnostics.zig");
const identity = @import("identity.zig");
pub const declarations = @import("declarations.zig");
const declaration_index = declarations.registration;
const generics = @import("generics.zig");
const generic_origins = @import("generic_origins.zig");
const generic_shapes = generics.shapes;
pub const lookup = declarations.Lookup(SemaContext);
const ownership_owner = @import("ownership.zig");
const asm_owner = @import("asm.zig");
const abi_owner = @import("abi.zig");
pub const protocol_conformance = protocols;
const protocols = @import("protocols.zig");
const session = @import("session.zig");
const semantic_types = @import("types.zig");
const type_resolution = @import("type_resolution.zig");
pub const value_semantics = sir;
const lexer = @import("../lexer/lexer.zig");
pub const package_manifest = @import("../package.zig");

pub const SemaError = error{ SemanticFailed, OutOfMemory };

const ConcurrencyTrampolines = concurrency.TrampolineOwner(.{
    .SemaContext = SemaContext,
    .SemaError = SemaError,
    .makeTypedExprFromId = makeTypedExprFromId,
    .finalizeAndRecordExprSemantics = finalizeAndRecordExprSemantics,
    .recordGeneratedBindingRoot = recordGeneratedBindingRoot,
    .internCallableType = internCallableType,
    .semanticExprMetadata = semanticExprMetadata,
    .recordExprMetadata = recordExprMetadata,
    .recordExprSink = recordExprSink,
    .parseType = parseType,
    .attachCheckedCallUse = attachCheckedCallUse,
});
const synthesizeTaskGroupTrampoline = ConcurrencyTrampolines.synthesizeTaskGroupTrampoline;
const synthesizeHostedThreadTrampoline = ConcurrencyTrampolines.synthesizeHostedThreadTrampoline;
const body_owner = @import("body.zig");
const BodyOwner = body_owner.Owner(.{
    .SemaContext = SemaContext,
    .SemaError = SemaError,
    .GlobalBinding = GlobalBinding,
    .LocalBinding = LocalBinding,
    .finalizeAndRecordExprSemantics = finalizeAndRecordExprSemantics,
    .instantiateGenericStructWithTypeArgs = instantiateGenericStructWithTypeArgs,
    .makeTypedExprFromId = makeTypedExprFromId,
    .maybeRecordSemanticHoverFact = maybeRecordSemanticHoverFact,
    .parseCanonicalType = parseCanonicalType,
    .borrowedPlaceDependencyForStoredValue = borrowedPlaceDependencyForStoredValue,
    .loweredCAbiSymbolName = loweredCAbiSymbolName,
    .recordExprSink = recordExprSink,
    .rootedBorrowProvenanceForType = rootedBorrowProvenanceForType,
    .declarationSpan = declarationSpan,
    .internCallableType = internCallableType,
    .provenanceCanEscapeFunction = provenanceCanEscapeFunction,
    .emitCallBorrowEscape = emitCallBorrowEscape,
    .callEscapeTarget = callEscapeTarget,
    .provenanceOutlivesTarget = provenanceOutlivesTarget,
    .InstantiatedStructDecl = InstantiatedStructDecl,
    .TypedExpr = TypedExpr,
    .GenericReceiverOrigin = GenericReceiverOrigin,
    .Provenance = Provenance,
    .packedFieldViolation = packedFieldViolation,
    .isPackedFieldType = StructLowering.isPackedFieldType,
    .isPackedStructType = StructLowering.isPackedStructType,
    .sharedRuntimeForContract = StructLowering.sharedRuntimeForContract,
    .dropRuntimeForContract = StructLowering.dropRuntimeForContract,
    .parseType = parseType,
    .placeholder_generic_scope = placeholder_generic_scope,
    .resolvePlace = resolvePlace,
    .semanticExprMetadata = semanticExprMetadata,
    .buildCheckedPlaceProjections = buildCheckedPlaceProjections,
    .isCAbiScalarTypeName = isCAbiScalarTypeName,
    .lowerComptimeExpr = lowerComptimeExpr,
    .isDefinitionSiteBinder = isDefinitionSiteBinder,
    .recordExprMetadata = recordExprMetadata,
    .LoweredAnonymousFunction = LoweredAnonymousFunction,
    .ResultCasePayload = ResultCasePayload,
    .expectAsmResultType = expectAsmResultType,
    .MethodUseKey = MethodUseKey,
    .ShapeProjection = ShapeProjection,
    .declaration_index = declaration_index,
    .markLocalHandedOff = markLocalHandedOff,
    .parseTypeWithBindings = parseTypeWithBindings,
    .rejectProjectedResourceTransferForTypedValue = rejectProjectedResourceTransferForTypedValue,
    .validateAsmExprPlaceholders = validateAsmExprPlaceholders,
    .expectAsmInputType = expectAsmInputType,
    .lowerImplicitHandoff = lowerImplicitHandoff,
    .recordGeneratedBindingRoot = recordGeneratedBindingRoot,
    .InstantiatedStructField = InstantiatedStructField,
    .lowerAsmConstraint = lowerAsmConstraint,
    .markCheckedNamedHandoff = markCheckedNamedHandoff,
    .lowerAsmClobber = lowerAsmClobber,
    .rejectArrowCallableStorageType = rejectArrowCallableStorageType,
    .typeMayCarryBorrowedProvenance = typeMayCarryBorrowedProvenance,
    .emitUnavailableLocal = emitUnavailableLocal,
    .provenanceOutlivesScope = provenanceOutlivesScope,
    .typeIsOwnedValue = OwnershipTypeAnalysis.canonicalTypeIsOwnedValue,
    .emitOwnershipDiagnostic = emitOwnershipDiagnostic,
    .checkedStoredBorrowDependency = checkedStoredBorrowDependency,
    .rejectIsolatedMutableGlobalAccess = rejectIsolatedMutableGlobalAccess,
    .TakeAstStep = TakeAstStep,
    .typeMayCaptureAllocator = OwnershipTypeAnalysis.canonicalTypeMayCaptureAllocator,
    .exprCarriesScopedAlloc = exprCarriesScopedAlloc,
    .findAstFunction = findAstFunction,
    .selectSyntaxMethod = selectSyntaxMethod,
    .validateAsmPlaceholders = validateAsmPlaceholders,
    .CheckedMethodAuthority = CheckedMethodAuthority,
    .ResolvedAstFunction = ResolvedAstFunction,
    .UnknownValueKind = UnknownValueKind,
    .attachCheckedCallUse = attachCheckedCallUse,
    .BuiltinSequenceLiteralKind = BuiltinSequenceLiteralKind,
    .LoweredTakePlace = LoweredTakePlace,
    .TypeExpectationOrigin = TypeExpectationOrigin,
    .canonicalBaseStructDecl = canonicalBaseStructDecl,
    .findLiteralField = findLiteralField,
    .projectedReadValueSemantics = projectedReadValueSemantics,
    .queryViewSourceBorrowRoots = queryViewSourceBorrowRoots,
    .rejectIsolatedCallToFunction = rejectIsolatedCallToFunction,
    .rejectLiveBorrowInvalidation = rejectLiveBorrowInvalidation,
    .syntaxMethodReturnType = syntaxMethodReturnType,
    .BuiltinLenKind = BuiltinLenKind,
    .LoweredHomogeneousLiteralItems = LoweredHomogeneousLiteralItems,
    .localMutationTargetScopeDepth = localMutationTargetScopeDepth,
    .rejectLiveBorrowPlaceMutationConflict = rejectLiveBorrowPlaceMutationConflict,
    .rejectProjectedBindingWritableAliasConflict = OwnershipTypeAnalysis.rejectProjectedBindingWritableAliasConflict,
    .rejectProjectedBindingMutableAliasCreation = OwnershipTypeAnalysis.rejectProjectedBindingMutableAliasCreation,
    .rejectProjectedBindingWritableCall = OwnershipTypeAnalysis.rejectProjectedBindingWritableCall,
    .typeIsOwnedForProtocol = typeIsOwnedForProtocol,
    .validateBoundaryCall = validateBoundaryCall,
    .BuiltinClearKind = BuiltinClearKind,
    .ConcreteCall = ConcreteCall,
    .expectMutableReceiver = expectMutableReceiver,
    .provenanceRootToken = provenanceRootToken,
    .rawPointeeTypeName = rawPointeeTypeName,
    .rejectScopedAllocCallEscape = rejectScopedAllocCallEscape,
    .summarizeBorrowEscapeRelation = OwnershipTypeAnalysis.summarizeBorrowEscapeRelation,
    .synthesizeHostedThreadTrampoline = synthesizeHostedThreadTrampoline,
    .BuiltinContainsKind = BuiltinContainsKind,
    .isBorrowProducingViewExpr = isBorrowProducingViewExpr,
    .parseTypeDepth = parseTypeDepth,
    .placeRootProvenance = placeRootProvenance,
    .rejectBorrowedProvenanceAssignmentEscape = rejectBorrowedProvenanceAssignmentEscape,
    .rejectLiveBorrowContainerMutationConflict = rejectLiveBorrowContainerMutationConflict,
    .synthesizeTaskGroupTrampoline = synthesizeTaskGroupTrampoline,
    .TypeBuiltinInsertMethod = TypeBuiltinInsertMethod,
    .exprCarriesScopedAllocAs = exprCarriesScopedAllocAs,
    .TypeBuiltinReserveMethod = TypeBuiltinReserveMethod,
    .emitScopedAllocEscape = emitScopedAllocEscape,
    .rejectBorrowedProvenanceMutationEscape = rejectBorrowedProvenanceMutationEscape,
    .TypeBuiltinPopMethod = TypeBuiltinPopMethod,
    .accumulateBorrowRootMutationProvenance = accumulateBorrowRootMutationProvenance,
    .rejectScopedAllocMutationEscape = rejectScopedAllocMutationEscape,
    .recordMutationProvenance = recordMutationProvenance,
    .constIndexValue = constIndexValue,
    .expectMutablePlaceRoot = expectMutablePlaceRoot,
    .normalizedStructReceiverType = OwnershipTypeAnalysis.normalizedStructReceiverType,
    .GenericContractFunction = GenericContractFunction,
    .LoopBlockChannelsResult = LoopBlockChannelsResult,
    .instantiateMethodCall = instantiateMethodCall,
    .typeIteratorInitRole = typeIteratorInitRole,
    .LoopStmtChannels = LoopStmtChannels,
    .typeIteratorHookRole = typeIteratorHookRole,
    .validateBoundaryArguments = validateBoundaryArguments,
    .typeIsThreadTransferable = typeIsThreadTransferable,
    .typeIteratorReadRole = typeIteratorReadRole,
    .IteratorHookSource = IteratorHookSource,
    .optionalEql = optionalEql,
    .rejectBorrowedProvenanceReturnEscape = rejectBorrowedProvenanceReturnEscape,
});
const lowerGenericDefinitionBodies = BodyOwner.lowerGenericDefinitionBodies;
const verifyCheckedGenericMethodBodies = BodyOwner.verifyCheckedGenericMethodBodies;
const lowerFunction = BodyOwner.lowerFunction;
const lowerInlineTestFunction = BodyOwner.lowerInlineTestFunction;
const global_owner = declarations.global_lowering;
const GlobalOwner = global_owner.Owner(.{
    .SemaContext = SemaContext,
    .SemaError = SemaError,
    .GlobalBinding = GlobalBinding,
    .parseCanonicalType = parseCanonicalType,
    .rejectArrowCallableStorageType = rejectArrowCallableStorageType,
    .typeIsOwnedValue = OwnershipTypeAnalysis.canonicalTypeIsOwnedValue,
    .maybeRecordSemanticHoverFact = maybeRecordSemanticHoverFact,
    .rootedBorrowProvenanceForType = rootedBorrowProvenanceForType,
    .loweredCAbiSymbolName = loweredCAbiSymbolName,
    .lowerExprInContext = lowerExprInContext,
    .recordExprSink = recordExprSink,
    .semanticExprMetadata = semanticExprMetadata,
    .resolveComptimeMetadata = resolveComptimeMetadata,
});
const lowerGlobal = GlobalOwner.lowerGlobal;
const syntax_roles = protocols.syntax_roles;
const SyntaxRoles = syntax_roles.Owner(.{
    .SemaContext = SemaContext,
    .SemaError = SemaError,
    .GlobalBinding = GlobalBinding,
    .canonicalBaseStructDecl = canonicalBaseStructDecl,
    .instantiateMethodCall = instantiateMethodCall,
    .parseTypeWithBindings = parseTypeWithBindings,
});
const StructLowering = declarations.lowering.Owner(.{
    .SemaContext = SemaContext,
    .SemaError = SemaError,
    .parseCanonicalType = parseCanonicalType,
    .parseType = parseType,
    .validateSliceViewMethods = SyntaxRoles.validateSliceViewMethods,
    .validateSyntaxMethods = SyntaxRoles.validateSyntaxMethods,
    .ownershipClass = ownershipClass,
    .canonicalTypeIsCStructFieldType = canonicalTypeIsCStructFieldType,
    .emitCStructFieldTypeError = emitCStructFieldTypeError,
});
const lowerEnum = StructLowering.lowerEnum;
const lowerUnion = StructLowering.lowerUnion;
const lowerStruct = StructLowering.lowerStruct;
const checkStructs = StructLowering.checkStructs;
const packedFieldViolation = StructLowering.packedFieldViolation;
const emitPackedFieldViolation = StructLowering.emitPackedFieldViolation;
pub const isPackedStructType = StructLowering.isPackedStructType;

const GenericAdmission = generics.admission.Owner(.{
    .SemaContext = SemaContext,
    .SemaError = SemaError,
    .parseCanonicalType = parseCanonicalType,
    .canonicalTypeKind = canonicalTypeKind,
    .validateTypeName = validateTypeName,
});
const checkGenericDecls = GenericAdmission.checkGenericDecls;

// Method-call instantiation is owned by the generics module. The body owner
// host table takes the entry-module relay below rather than this namespace
// value: the body owner already reaches the entry module, so holding the
// namespace value there closes a comptime dependency loop.
const MethodInstantiation = generics.instantiation.Owner(.{
    .SemaContext = SemaContext,
    .SemaError = SemaError,
    .GlobalBinding = GlobalBinding,
    .TypedExpr = TypedExpr,
    .registeredDeclId = lookup.registeredDeclId,
    .instantiateGenericStructMethodForCall = BodyOwner.instantiateGenericStructMethodForCall,
    .resolveExplicitGenericArgs = resolveExplicitGenericArgs,
    .unifyGenericBinding = unifyGenericBinding,
    .typeIsOwnedForProtocol = typeIsOwnedForProtocol,
});
const AbiOwner = abi_owner.Owner(.{
    .SemaContext = SemaContext,
    .SemaError = SemaError,
    .TypedExpr = TypedExpr,
    .makeTypedExprFromId = makeTypedExprFromId,
    .allCanonicalAggregateFieldTypesSatisfy = allCanonicalAggregateFieldTypesSatisfy,
});
const checkCallableBoundaryDecls = AbiOwner.checkCallableBoundaryDecls;
const loweredCAbiSymbolName = AbiOwner.loweredCAbiSymbolName;
const emitCStructFieldTypeError = AbiOwner.emitCStructFieldTypeError;
const canonicalTypeIsCStructFieldType = AbiOwner.canonicalTypeIsCStructFieldType;
const lowerComptimeExpr = AbiOwner.lowerComptimeExpr;
const resolveComptimeMetadata = AbiOwner.resolveComptimeMetadata;
const isPlainCStrTypeName = AbiOwner.isPlainCStrTypeName;
const rawPointeeTypeName = AbiOwner.rawPointeeTypeName;
const isCAbiScalarTypeName = AbiOwner.isCAbiScalarTypeName;

const AsmOwner = asm_owner.Owner(.{
    .SemaContext = SemaContext,
    .SemaError = SemaError,
    .isDefinitionSiteBinder = isDefinitionSiteBinder,
});
const lowerAsmConst = GlobalOwner.lowerAsmConst;
const expectAsmInputType = AsmOwner.expectAsmInputType;
const expectAsmResultType = AsmOwner.expectAsmResultType;
const lowerAsmConstraint = AsmOwner.lowerAsmConstraint;
const lowerAsmClobber = AsmOwner.lowerAsmClobber;
const validateAsmPlaceholders = AsmOwner.validateAsmPlaceholders;
const validateAsmExprPlaceholders = AsmOwner.validateAsmExprPlaceholders;

const CheckedEffectOwner = effects.Owner(.{
    .SemaContext = SemaContext,
    .SemaError = SemaError,
    .semanticExprMetadata = semanticExprMetadata,
});
const SirFinalization = sir_finalization.Owner(.{
    .SemaContext = SemaContext,
    .SemaError = SemaError,
    .semanticExprMetadata = semanticExprMetadata,
});
const buildCheckedPlaceProjections = CheckedEffectOwner.buildCheckedPlaceProjections;
const transferActionForExpr = CheckedEffectOwner.transferActionForExpr;
const recordExprMetadata = CheckedEffectOwner.recordExprMetadata;
const recordExprSink = CheckedEffectOwner.recordExprSink;
const recordGeneratedBindingRoot = CheckedEffectOwner.recordGeneratedBindingRoot;
const attachCheckedCallUse = CheckedEffectOwner.attachCheckedCallUse;

pub const BuildOptions = session.BuildOptions;
pub const SliceViewNormalization = session.SliceViewNormalization;
pub const IndexCastNormalization = session.IndexCastNormalization;

/// Definition-site authority travels with a value independently of its
/// substituted concrete TypeId. Never infer this by comparing concrete types.
const GenericReceiverOrigin = generic_shapes.Origin;

/// Scope id reserved for the placeholder types lowering interns for results
/// whose concrete type is still open at the definition site.
const placeholder_generic_scope: identity.GenericScopeId = @fromBackingInt(@intCast(std.math.maxInt(u32)));

/// The layer a lowered projection reaches inside the shape the body recorded for
/// a receiver: the item of a container, the payload of an optional or a result,
/// or the view a slice takes of it. A join keeps each side's layer separate so
/// every binder the projection can reach still names its own origin.
const ShapeProjection = enum { iter_item, index, slice, payload };

const MethodUseKey = session.MethodUseKey;

const CheckedMethodAuthority = struct {
    protocol: identity.DeclId,
    method: identity.DeclId,
    use_id: u32,
};

const GenericContractFunction = session.GenericContractFunction;

pub const SemaContext = session.Context(struct {
    pub const Local = LocalBinding;
    pub const ThreadFrame = concurrency.ThreadBoundaryFrame;
    pub const Worklist = BorrowSummaryWorklist;
    pub const ActiveSummary = ActiveBorrowSummary;
    pub const CachedSummary = CachedBorrowSummary;
    pub const SummaryDependency = BorrowSummaryDependency;
    pub const GenericScopeRegistry = generic_origins.ScopeRegistry;
    pub const ProtocolConformanceRegistry = protocol_conformance.Registry;
});

pub const canonical = type_resolution.Canonical(SemaContext);
const checkedCaptureOrigin = BodyOwner.checkedCaptureOrigin;
pub const packedStructBitWidth = BodyOwner.packedStructBitWidth;
const lowerInstantiatedStruct = BodyOwner.lowerInstantiatedStruct;
const checkedCapturePath = BodyOwner.checkedCapturePath;
pub const typeEqual = BodyOwner.typeEqual;
const resolutionPolicy = BodyOwner.resolutionPolicy;
pub const registeredOrGeneratedDeclId = BodyOwner.registeredOrGeneratedDeclId;
const recordMethodUse = BodyOwner.recordMethodUse;
pub const parseTypeWithSelf = BodyOwner.parseTypeWithSelf;
const moduleSourcePath = BodyOwner.moduleSourcePath;
pub const makeTypedExprWithProvenanceAndValueSemantics = BodyOwner.makeTypedExprWithProvenanceAndValueSemantics;
const WitnessSynthesis = protocols.witness_synthesis.Owner(.{
    .SemaContext = SemaContext,
    .SemaError = SemaError,
    .parseType = parseType,
    .parseTypeWithSelf = parseTypeWithSelf,
    .makeTypedExprFromId = makeTypedExprFromId,
    .finalizeAndRecordExprSemantics = finalizeAndRecordExprSemantics,
    .recordGeneratedBindingRoot = recordGeneratedBindingRoot,
    .attachCheckedCallUse = attachCheckedCallUse,
    .recordExprSink = recordExprSink,
    .checkedCapturePath = checkedCapturePath,
    .checkedCaptureOrigin = checkedCaptureOrigin,
    .registeredOrGeneratedDeclId = registeredOrGeneratedDeclId,
});

const makeTypedExprFromIdWithProvenance = BodyOwner.makeTypedExprFromIdWithProvenance;
pub const makeTypedExpr = BodyOwner.makeTypedExpr;
const lowerExprInContext = BodyOwner.lowerExprInContext;
pub const localBinding = BodyOwner.localBinding;
const instantiateGenericStructMethodForCall = BodyOwner.instantiateGenericStructMethodForCall;
const appendOwnedLowered = BodyOwner.appendOwnedLowered;
const canonicalTypeNode = canonical.typeNode;
const canonicalTypeKind = canonical.sirType;
const internCallableType = canonical.internCallableType;

pub const SemanticHoverFact = session.SemanticHoverFact;

const InstantiatedStructField = session.InstantiatedStructField;

const InstantiatedStructDecl = session.InstantiatedStructDecl;

const LoweredAnonymousFunction = struct {
    function: sir.Function,
    captures: []const LocalBinding = &.{},
    env_type_name: ?[]const u8 = null,
    env_decl_id: ?identity.DeclId = null,

    pub fn deinit(self: LoweredAnonymousFunction, allocator: std.mem.Allocator) void {
        self.function.deinit(allocator);
        allocator.free(self.captures);
    }
};

pub fn buildSir(allocator: std.mem.Allocator, path: []const u8, program: ast.Program) SemaError!sir.Module {
    return buildSirWithOptions(allocator, path, program, .{});
}

/// Definition-site requirement records. Every generic declaration's body is
/// lowered at its own declaration, and that lowering records each method use
/// and operation the body performs in the shared record list, keyed by
/// declaration and call-site position, so a lowered body and a requirement never
/// disagree about which use an authority belongs to. This pass verifies the
/// identity each record carries and gives every protocol-bearing use a stable
/// use id; no parallel walk of the declaration's syntax decides admission.
fn collectGenericRequirements(context: *SemaContext) SemaError!void {
    for (context.generic.method_use_records.items, 0..) |_, index| {
        const requirement = &context.generic.method_use_records.items[index];
        if (requirement.declaration_id == null) return error.SemanticFailed;
        const offset = requirement.parameter_definition_offset orelse return error.SemanticFailed;
        const parameter_id = requirement.parameter_id orelse return error.SemanticFailed;
        if (!context.generic_scopes.?.verifySourceParam(requirement.module_name, offset, parameter_id)) return error.SemanticFailed;
        // One stable id per source method use: requirements that record the same
        // declaration and call site describe one use, and each lowered use of it
        // carries that id.
        if (requirement.declared_protocol != null and requirement.use_id == null) {
            requirement.use_id = try recordMethodUse(context, requirement.*);
        }
    }
}

pub fn collectSemanticHoverFacts(
    allocator: std.mem.Allocator,
    path: []const u8,
    program: ast.Program,
    module_name: []const u8,
) SemaError![]SemanticHoverFact {
    return collectSemanticHoverFactsWithOptions(allocator, path, program, module_name, .{});
}

pub fn collectSemanticHoverFactsWithOptions(
    allocator: std.mem.Allocator,
    path: []const u8,
    program: ast.Program,
    module_name: []const u8,
    options: BuildOptions,
) SemaError![]SemanticHoverFact {
    var facts: std.ArrayListUnmanaged(SemanticHoverFact) = .empty;
    errdefer {
        for (facts.items) |fact| fact.deinit(allocator);
        facts.deinit(allocator);
    }

    var context = SemaContext.init(allocator, options);
    context.semantic_hover = .{
        .module_name = module_name,
        .facts = &facts,
    };
    var module = try buildSirWithContext(&context, path, program);
    defer module.deinit(allocator);
    return try facts.toOwnedSlice(allocator);
}

pub fn buildSirWithOptions(allocator: std.mem.Allocator, path: []const u8, program: ast.Program, options: BuildOptions) SemaError!sir.Module {
    var context = SemaContext.init(allocator, options);
    return buildSirWithContext(&context, path, program);
}

fn buildSirWithContext(context: *SemaContext, path: []const u8, program: ast.Program) SemaError!sir.Module {
    const allocator = context.allocator;
    var phase: @import("../session.zig").Scope = if (context.options.timing_session) |timing_session| timing_session.start("sema.setup", &.{}) else .{};
    defer phase.end();
    errdefer phase.endError();
    try context.prepare();
    defer context.function_state = .{};
    defer context.borrow_summaries.active_worklist = null;
    defer context.deinitAnalysisState();
    defer context.deinitCanonicalState();
    errdefer context.deinitFailedOutputs();
    errdefer context.generic.deinitDeferredShapes(allocator);
    try declarations.checkNames(&context.diagnostic_context, path, program);
    context.declarations.registry = try declarations.registration.build(allocator, path, program);
    defer context.deinitIdentityRegistry();
    context.generic_scopes = generic_origins.ScopeRegistry.init(allocator, &context.declarations.registry.?);
    context.generic_scopes.?.registerProgram(program) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SemanticFailed,
    };

    try registerPendingGeneratedDecls(context, program);
    phase.end();
    phase = if (context.options.timing_session) |timing_session| timing_session.start("sema.declarations", &.{}) else .{};
    // Alias validation can parse directly into canonical IDs once declaration
    // identity exists; alias registration itself still follows validation.
    try checkTypeAliases(context, path, program);
    try registerCanonicalAliasTypes(context, path, program);
    try protocols.checkDeclarations(SemaContext, TypeParser.parseTypeDepth, context, path, program);
    // Conformance identity must exist before declarations instantiate
    // constrained generic types. Witness validation remains in its normal
    // phase below; this pass only establishes canonical (type, protocol) keys.
    try protocols.registerImplConformances(SemaContext, TypeParser.parseTypeDepth, typeIsOwnedForProtocol, context, path, program);
    try checkStructs(context, path, program);
    try checkGenericDecls(context, path, program);
    try protocols.checkImpls(SemaContext, TypeParser.parseTypeDepth, typeIsOwnedForProtocol, context, path, program);
    try checkCallableBoundaryDecls(context, path, program);
    try rejectUnsupportedAbstractionSurface(path, program);
    try checkStdModuleAvailability(context, path, program);
    phase.end();
    phase = if (context.options.timing_session) |timing_session| timing_session.start("sema.decl_lowering", &.{}) else .{};

    var globals: std.ArrayListUnmanaged(sir.Global) = .empty;
    errdefer {
        for (globals.items) |global| global.deinit(allocator);
        globals.deinit(allocator);
    }

    var asm_consts: std.ArrayListUnmanaged(sir.AsmConst) = .empty;
    errdefer asm_consts.deinit(allocator);

    var global_bindings: std.ArrayListUnmanaged(GlobalBinding) = .empty;
    defer global_bindings.deinit(allocator);

    for (program.globals) |global| {
        const lowered = try lowerGlobal(context, path, program, global_bindings.items, global);
        var owns_lowered_global = true;
        errdefer if (owns_lowered_global) lowered.global.deinit(allocator);
        try globals.append(allocator, lowered.global);
        owns_lowered_global = false;
        try global_bindings.append(allocator, lowered.binding);
    }

    for (program.asm_consts) |asm_const| {
        try asm_consts.append(allocator, try lowerAsmConst(context, path, program, global_bindings.items, asm_const));
    }

    var enums: std.ArrayListUnmanaged(sir.EnumDecl) = .empty;
    errdefer {
        for (enums.items) |decl| decl.deinit(allocator);
        enums.deinit(allocator);
    }

    for (program.enums) |decl| {
        try appendOwnedLowered(allocator, &enums, try lowerEnum(context, decl));
    }

    var unions: std.ArrayListUnmanaged(sir.UnionDecl) = .empty;
    errdefer {
        for (unions.items) |decl| decl.deinit(allocator);
        unions.deinit(allocator);
    }

    for (program.unions) |decl| {
        try appendOwnedLowered(allocator, &unions, try lowerUnion(context, path, program, decl));
    }

    var structs: std.ArrayListUnmanaged(sir.StructDecl) = .empty;
    errdefer {
        for (structs.items) |decl| decl.deinit(allocator);
        structs.deinit(allocator);
    }

    for (program.structs) |decl| {
        if (decl.type_params.len == 0) {
            try appendOwnedLowered(allocator, &structs, try lowerStruct(context, path, program, decl));
        }
    }

    phase.end();
    phase = if (context.options.timing_session) |timing_session| timing_session.start("sema.bodies.generics", &.{}) else .{};

    // Definition-site lowering records every method use a generic declaration
    // makes before any witness specializes it, so specialization and lowering
    // consume records the body itself produced.
    try lowerGenericDefinitionBodies(context, path, program, global_bindings.items, structs.items, unions.items);
    // The requirement walk runs after the definition-site flow, so a use the
    // checked body already settled is recorded from that flow; the walk only
    // reconstructs the uses the flow could not model.
    try collectGenericRequirements(context);
    phase.end();
    phase = if (context.options.timing_session) |timing_session| timing_session.start("sema.bodies.free_functions", &.{}) else .{};
    // Generated hook uses draw from the same id space as source uses, so the
    // counter already sits above every recorded source use.

    var functions: std.ArrayListUnmanaged(sir.Function) = .empty;
    errdefer {
        for (functions.items) |function| function.deinit(allocator);
        functions.deinit(allocator);
    }

    var tests: std.ArrayListUnmanaged(sir.InlineTest) = .empty;
    errdefer tests.deinit(allocator);

    for (program.functions) |function| {
        if (function.type_params.len == 0 and !isGenericOwnerMethod(program, function)) {
            try functions.ensureUnusedCapacity(allocator, 1);
            functions.appendAssumeCapacity(try lowerFunction(context, path, program, global_bindings.items, function));
        }
    }

    phase.end();
    phase = if (context.options.timing_session) |timing_session| timing_session.start("sema.bodies.struct_methods", &.{}) else .{};
    for (program.structs) |decl| {
        if (decl.type_params.len != 0) continue;
        for (decl.methods) |method| {
            if (method.type_params.len == 0) {
                try functions.ensureUnusedCapacity(allocator, 1);
                functions.appendAssumeCapacity(try lowerFunction(context, path, program, global_bindings.items, method));
            }
        }
    }

    phase.end();
    phase = if (context.options.timing_session) |timing_session| timing_session.start("sema.bodies.impl_methods", &.{}) else .{};
    for (program.impls) |decl| {
        if (decl.type_params.len != 0) continue;
        for (decl.methods) |method| {
            try functions.ensureUnusedCapacity(allocator, 1);
            functions.appendAssumeCapacity(try lowerFunction(context, path, program, global_bindings.items, method));
        }
    }

    phase.end();
    phase = if (context.options.timing_session) |timing_session| timing_session.start("sema.bodies.generated", &.{}) else .{};
    try WitnessSynthesis.materializeDerivedWitnesses(context, path, program, &functions);

    for (program.tests, 0..) |inline_test, i| {
        const lowered_name = try std.fmt.allocPrint(allocator, "{s}{d}", .{ generated_names.test_function_prefix, i });
        errdefer allocator.free(lowered_name);
        const decl_id = (try lookup.registerGeneratedDecl(context, inline_test.module_name, null, lowered_name, .function)) orelse
            return error.SemanticFailed;
        var lowered_function = try lowerInlineTestFunction(context, path, program, global_bindings.items, inline_test, lowered_name, decl_id);
        lowered_function.decl_id = decl_id;
        errdefer lowered_function.deinit(allocator);
        try functions.append(allocator, lowered_function);
        try tests.append(allocator, .{
            .module_name = inline_test.module_name,
            .name = inline_test.name,
            .function_name = lowered_name,
        });
    }

    // Reserve before transferring any functions: a partial append followed by
    // OOM must not leave the same functions owned by both cleanup paths.
    try context.generic.transferInstantiatedFunctions(allocator, &functions);

    try structs.ensureUnusedCapacity(allocator, context.generic.instantiated_structs.items.len);
    for (context.generic.instantiated_structs.items) |decl| {
        structs.appendAssumeCapacity(try lowerInstantiatedStruct(context, decl));
    }

    context.generic.deinitInstantiatedStructs(allocator);
    // The instantiated declarations have been consumed into `structs`. Late
    // validation below may still fail, so leave the context in an empty,
    // deinitializable state for buildSirWithContext's error cleanup.

    phase.end();
    phase = if (context.options.timing_session) |timing_session| timing_session.start("sema.bodies.verify", &.{}) else .{};
    if (verifyCheckedGenericMethodBodies(context, path, functions.items, structs.items, unions.items, context.expr_metadata.items)) |_| {} else |err| {
        return err;
    }

    phase.end();
    phase = if (context.options.timing_session) |timing_session| timing_session.start("sema.finalize", &.{}) else .{};
    const result = try SirFinalization.finish(context, allocator, .{
        .globals = &globals,
        .asm_consts = &asm_consts,
        .enums = &enums,
        .unions = &unions,
        .structs = &structs,
        .functions = &functions,
        .tests = &tests,
    });
    phase.end();
    return result;
}

fn registerPendingGeneratedDecls(context: *SemaContext, program: ast.Program) SemaError!void {
    for (context.generic.instantiated_structs.items) |*decl| {
        if (decl.id != null) continue;
        decl.id = (try lookup.registerGeneratedDecl(context, decl.module_name, null, decl.name, .@"struct")) orelse
            return error.SemanticFailed;
        if (decl.base_decl_id == null) {
            if (findStructInModule(program, decl.module_name, decl.base_name)) |base_decl| {
                decl.base_decl_id = try lookup.registeredDeclId(context, base_decl.module_name, null, base_decl.name, .@"struct");
            }
        }
    }
}

fn checkStdModuleAvailability(context: *SemaContext, path: []const u8, program: ast.Program) SemaError!void {
    const allocator = context.allocator;
    const target_id = targetSupportId(context) catch |err| {
        try context.diagnostic_context.emitPath(path, @errorName(err));
        return switch (err) {
            error.OutOfMemory => SemaError.OutOfMemory,
            else => SemaError.SemanticFailed,
        };
    };
    defer allocator.free(target_id);

    for (program.module_infos) |info| {
        for (info.imports) |decl| {
            const supported = package_manifest.bundledModuleSupportsTarget(allocator, decl.path, target_id) catch |err| {
                try context.diagnostic_context.emitPath(path, @errorName(err));
                return SemaError.SemanticFailed;
            } orelse continue;
            if (!supported) {
                const message = std.fmt.allocPrint(allocator, "{s} is not available for target `{s}`", .{ decl.path, target_id }) catch {
                    return SemaError.OutOfMemory;
                };
                defer allocator.free(message);
                try context.diagnostic_context.emitPath(path, message);
                return SemaError.SemanticFailed;
            }
        }
    }
}

fn targetSupportId(context: *SemaContext) ![]const u8 {
    const support = try build_model.supportedTargetSupport(context.options.target);
    return context.allocator.dupe(u8, support.id);
}

fn rejectUnsupportedAbstractionSurface(path: []const u8, program: ast.Program) SemaError!void {
    _ = path;
    _ = program;
}
// SIR module function finding is owned by the declaration module; the entry
// point only re-exports it for `buildSir` callers and the test lanes.
pub const findFunction = declarations.findSirFunction;
pub const findFunctionIn = declarations.findSirFunctionIn;

// Struct, union, and enum declaration lookup is owned by `declarations.zig`;
// the entry point only borrows it for its own sequencing and tests.
const StructLookup = declarations.StructLookup;
const StructFieldLookup = declarations.StructFieldLookup;
const findInstantiatedStruct = lookup.findInstantiatedStruct;
const canonicalInstantiatedStructTypeId = lookup.canonicalInstantiatedStructTypeId;
const canonicalBaseStructDecl = lookup.canonicalBaseStructDecl;

// Field type resolution lives in the body owner, and the thread-boundary
// walker is reachable from the body owner's host table, so the walker takes a
// declaration relay instead of the owner namespace value.
fn structFieldTypeId(
    context: *SemaContext,
    path: []const u8,
    program: ast.Program,
    decl: StructLookup,
    field: StructFieldLookup,
) SemaError!semantic_types.TypeId {
    return BodyOwner.structFieldTypeId(context, path, program, decl, field);
}

// Aggregate field inspection lives in the body owner, but the ABI owner is
// reachable from the body owner, so the host table cannot take the owner's
// namespace value directly; a declaration relay breaks the dependency loop.
fn allCanonicalAggregateFieldTypesSatisfy(
    context: *SemaContext,
    path: []const u8,
    program: ast.Program,
    type_id: semantic_types.TypeId,
    comptime predicate: fn (*SemaContext, []const u8, ast.Program, semantic_types.TypeId) SemaError!bool,
) SemaError!bool {
    return BodyOwner.allCanonicalAggregateFieldTypesSatisfy(context, path, program, type_id, predicate);
}

const isGenericOwnerMethod = Lookup.isGenericOwnerMethod;

const BoundaryWalk = concurrency.Walker(.{
    .SemaContext = SemaContext,
    .SemaError = SemaError,
    .GlobalBinding = GlobalBinding,
    .findAstFunction = findAstFunction,
    .structFieldTypeId = structFieldTypeId,
    .parseTypeWithBindings = parseTypeWithBindings,
    .parseType = parseType,
});
pub const analyzeThreadBoundaryEntrypoint = BoundaryWalk.analyzeThreadBoundaryEntrypoint;
pub const validateBoundaryCall = BoundaryWalk.validateBoundaryCall;
const validateBoundaryArguments = BoundaryWalk.validateBoundaryArguments;
const rejectIsolatedMutableGlobalAccess = BoundaryWalk.rejectIsolatedMutableGlobalAccess;
pub const rejectIsolatedCallToFunction = BoundaryWalk.rejectIsolatedCallToFunction;
pub const typeIsThreadTransferable = BoundaryWalk.typeIsThreadTransferable;
pub const typeIsThreadShareable = BoundaryWalk.typeIsThreadShareable;
pub const firstNonTransferableResourcePath = BoundaryWalk.firstNonTransferableResourcePath;

const LoopStmtChannels = struct {
    stmt: sir.Stmt,
    fallthrough_state: ?[]LocalBinding,
    continue_state: ?[]LocalBinding,
    break_state: ?[]LocalBinding,
};

const LoopBlockChannelsResult = struct {
    body: []const sir.Stmt,
    fallthrough_state: ?[]LocalBinding,
    continue_state: ?[]LocalBinding,
    break_state: ?[]LocalBinding,
};

const TakeAstStep = union(enum) {
    field: ast.FieldAccess,
    index: ast.Index,
};

const LoweredTakePlace = struct {
    local_name: []const u8,
    type_id: semantic_types.TypeId,
    steps: []const sir.TakePathStep,
    sparse_final_index: ?*sir.Expr = null,

    pub fn deinit(self: LoweredTakePlace, allocator: std.mem.Allocator) void {
        if (self.sparse_final_index) |index| index.destroy(allocator);
        for (self.steps) |step| switch (step) {
            .field => {},
            .index => |index| index.destroy(allocator),
        };
        allocator.free(self.steps);
    }
};

fn semanticExprMetadata(context: *SemaContext, expr: *const sir.Expr) ?sir.ExprMetadata {
    const index = context.expr_metadata_index.get(expr) orelse return null;
    return context.expr_metadata.items[index].metadata;
}

const ResultCasePayload = struct {
    expr: ?*sir.Expr,
    provenance: Provenance,
};

/// A binder stands for an unknown concrete type at its definition site. A check
/// that depends on the concrete kind -- storage lifetime, operator capability --
/// cannot be decided there, so the definition-site pass defers it; every
/// specialization re-checks the substituted type when its body is lowered.
fn isDefinitionSiteBinder(context: *SemaContext, type_id: semantic_types.TypeId) bool {
    return canonicalTypeNode(context, type_id).* == .generic_parameter;
}

const ConcreteCall = struct {
    module_name: []const u8,
    owner: ?[]const u8,
    name: []const u8,
    return_type_id: semantic_types.TypeId,
    return_provenance: Provenance,
    arg_exprs: []const *sir.Expr,
};

pub const BorrowEscapeRelation = callable_analysis.EscapeRelation(BorrowRootQuery, ownership_owner.normalizedRootsEqual);
const BorrowEscapeSummaryRelation = callable_analysis.EscapeSummaryRelation(BorrowEscapeRelation);
pub const BorrowSummaryParamFacts = callable_analysis.SummaryParamFacts;

pub const BorrowSummarySolveContext = struct {
    context: *SemaContext,
    allocator: std.mem.Allocator,
    path: []const u8,
    program: ast.Program,
    current_module: []const u8,
    globals: []const GlobalBinding,
    function: ast.Function,
    generic_args: ?[]const semantic_types.GenericArgument,
    summary_key: BorrowSummaryKey,
    facts: BorrowSummaryParamFacts,
};

const BorrowSummaryWorklist = OwnershipTypeAnalysis.BorrowSummaryWorklist;
pub const BorrowSummarySolver = OwnershipTypeAnalysis.BorrowSummarySolver;

const BorrowSummaryKey = ownership_owner.BorrowSummaryKey;
const BorrowSummaryDependency = ownership_owner.BorrowSummaryDependency;
const ActiveBorrowSummary = ownership_owner.ActiveBorrowSummary(BorrowEscapeRelation);
const CachedBorrowSummary = ownership_owner.CachedBorrowSummary(BorrowEscapeRelation);

pub const borrowSummaryKeyEql = OwnershipTypeAnalysis.borrowSummaryKeyEql;
pub const makeBorrowSummaryKey = OwnershipTypeAnalysis.makeBorrowSummaryKey;
pub const lookupBorrowSummaryRelation = OwnershipTypeAnalysis.lookupBorrowSummaryRelation;
pub const recordBorrowSummaryDependency = OwnershipTypeAnalysis.recordBorrowSummaryDependency;
pub const maybeRecordActiveBorrowSummaryDependency = OwnershipTypeAnalysis.maybeRecordActiveBorrowSummaryDependency;
pub const computeBorrowSummarySccs = OwnershipTypeAnalysis.computeBorrowSummarySccs;
pub const borrowSummaryKeyIsInCycle = OwnershipTypeAnalysis.borrowSummaryKeyIsInCycle;
pub const cacheBorrowSummaryRelation = OwnershipTypeAnalysis.cacheBorrowSummaryRelation;

const selectSyntaxMethod = SyntaxRoles.selectSyntaxMethod;
const syntaxMethodReturnType = SyntaxRoles.syntaxMethodReturnType;
const typeIteratorHookRole = SyntaxRoles.typeIteratorHookRole;
const typeIteratorInitRole = SyntaxRoles.typeIteratorInitRole;
const typeIteratorReadRole = SyntaxRoles.typeIteratorReadRole;

// The generics owner holds the instantiation logic itself. This relay exists so
// the body and syntax-role host tables can name it without evaluating the
// generics namespace value, which would close a comptime dependency loop.
fn instantiateMethodCall(
    context: *SemaContext,
    allocator: std.mem.Allocator,
    path: []const u8,
    program: ast.Program,
    globals: []const GlobalBinding,
    current_module: []const u8,
    lowered_owner: []const u8,
    method_token: lexer.Token,
    method: ast.Function,
    base_params: []const ast.GenericParam,
    base_args: []const semantic_types.GenericArgument,
    explicit_type_args: []const ast.TypeName,
    inferred_type_args: ?[]const TypedExpr,
) SemaError!generics.ResolvedMethodInstantiation {
    return MethodInstantiation.instantiateMethodCall(context, allocator, path, program, globals, current_module, lowered_owner, method_token, method, base_params, base_args, explicit_type_args, inferred_type_args);
}

pub const BorrowRootQuery = ownership_owner.BorrowRootQuery;

pub const markSummaryRootsToTargetRootSet = OwnershipTypeAnalysis.markSummaryRootsToTargetRootSet;
pub const summaryExprBorrowSourceFlags = OwnershipTypeAnalysis.summaryExprBorrowSourceFlags;

const callEscapeTarget = OwnershipTypeAnalysis.callEscapeTarget;

const BuiltinSequenceLiteralKind = enum {
    dense_array,
};

const LoweredHomogeneousLiteralItems = struct {
    items: []const *sir.Expr,
    combined_provenance: Provenance,
};

fn checkTypeAliases(context: *SemaContext, path: []const u8, program: ast.Program) SemaError!void {
    return TypeParser.checkTypeAliases(context, path, program);
}

pub fn registerCanonicalAliasTypes(context: *SemaContext, path: []const u8, program: ast.Program) SemaError!void {
    return TypeParser.registerCanonicalAliasTypes(context, path, program);
}

fn recordCanonicalGenericAlias(
    context: *SemaContext,
    alias: ast.TypeAlias,
    canonical_args: []const semantic_types.GenericArgument,
    resolved: semantic_types.TypeId,
) SemaError!void {
    if (context.declarations.registry == null or context.canonical.types == null) return;
    const decl_id = try lookup.registeredDeclId(context, alias.module_name, null, alias.name, .type_alias);
    return type_resolution.recordGenericAlias(context.allocator, &context.canonical, decl_id, canonical_args, resolved);
}

fn validateTypeName(
    context: *SemaContext,
    path: []const u8,
    program: ast.Program,
    current_module: []const u8,
    type_name: ast.TypeName,
    generic_params: []const ast.GenericParam,
    self_type: ?semantic_types.TypeId,
) SemaError!void {
    return TypeParser.validateTypeName(context, path, program, current_module, type_name, generic_params, self_type);
}

fn rejectArrowCallableStorageType(sema: *SemaContext, path: []const u8, token: lexer.Token, type_id: semantic_types.TypeId, storage_context: []const u8) SemaError!void {
    const node = canonicalTypeNode(sema, type_id).*;
    if (node != .callable or node.callable.kind != .arrow) return;
    try sema.diagnostic_context.emitToken(
        path,
        token,
        "non-escaping callable values cannot be stored by `{s}` because their capture environment is call-local; use `fn(...)` for a non-capturing stored callback, or store explicit context beside the function pointer",
        .{storage_context},
    );
    return SemaError.SemanticFailed;
}

const StructSpecializationSupport = .{
    .parseTypeDepth = parseTypeDepth,
    .typeIsOwnedForProtocol = typeIsOwnedForProtocol,
    .appendCanonicalTypeDisplay = canonical.appendTypeDisplay,
    .canonicalInstantiatedStructTypeId = canonicalInstantiatedStructTypeId,
    .isPlainCStrTypeName = isPlainCStrTypeName,
    .canonicalTypeIsCStructFieldType = canonicalTypeIsCStructFieldType,
    .emitCStructFieldTypeError = emitCStructFieldTypeError,
    .packedFieldViolation = packedFieldViolation,
    .emitPackedFieldViolation = emitPackedFieldViolation,
};

fn instantiateGenericStruct(
    context: *SemaContext,
    path: []const u8,
    program: ast.Program,
    current_module: []const u8,
    decl: ast.StructDecl,
    type_args: []const ast.TypeName,
    self_type: ?semantic_types.TypeId,
    generic_params: []const ast.GenericParam,
    generic_args: []const semantic_types.GenericArgument,
) SemaError!semantic_types.TypeId {
    return generics.instantiateGenericStruct(SemaContext, StructSpecializationSupport, context, path, program, current_module, decl, type_args, self_type, generic_params, generic_args);
}

const AliasSpecializationSupport = .{
    .parseTypeDepth = parseTypeDepth,
    .typeIsOwnedForProtocol = typeIsOwnedForProtocol,
    .canonicalTypeKind = canonicalTypeKind,
    .borrowOriginToken = borrowOriginToken,
    .resolvePlace = resolvePlace,
    .resolvedDistinctAliasType = canonical.resolveDistinctAliasType,
    .recordCanonicalGenericAlias = recordCanonicalGenericAlias,
};

fn instantiateTypeAlias(
    context: *SemaContext,
    path: []const u8,
    program: ast.Program,
    current_module: []const u8,
    alias: ast.TypeAlias,
    type_args: []const ast.TypeName,
    self_type: ?semantic_types.TypeId,
    generic_params: []const ast.GenericParam,
    generic_args: []const semantic_types.GenericArgument,
    depth: usize,
) SemaError!semantic_types.TypeId {
    return generics.instantiateTypeAlias(SemaContext, AliasSpecializationSupport, context, path, program, current_module, alias, type_args, self_type, generic_params, generic_args, depth);
}

fn instantiateGenericStructWithTypeArgs(
    context: *SemaContext,
    path: []const u8,
    program: ast.Program,
    decl: ast.StructDecl,
    lowered_args: []const semantic_types.GenericArgument,
) SemaError!semantic_types.TypeId {
    return generics.instantiateGenericStructWithTypeArgs(SemaContext, StructSpecializationSupport, context, path, program, decl, lowered_args);
}

fn maybeRecordSemanticHoverFact(
    context: *SemaContext,
    allocator: std.mem.Allocator,
    path: []const u8,
    program: ast.Program,
    current_module: []const u8,
    token: lexer.Token,
    headline: []const u8,
    type_id: semantic_types.TypeId,
    provenance: Provenance,
) SemaError!void {
    const collector = context.semantic_hover orelse return;
    if (!std.mem.eql(u8, current_module, collector.module_name)) return;

    const type_display = try canonical.formatType(context, type_id);
    defer allocator.free(type_display);

    var markdown = std.ArrayListUnmanaged(u8).empty;
    errdefer markdown.deinit(allocator);
    try markdown.print(allocator, "```cyna\n{s}: {s}\n```", .{ headline, type_display });

    if (try ownershipSummary(context, allocator, path, program, current_module, type_id)) |ownership| {
        defer allocator.free(ownership);
        try markdown.print(allocator, "\n\n**Ownership:** {s}", .{ownership});
    }
    if (provenanceSummary(allocator, provenance)) |prov| {
        defer allocator.free(prov);
        try markdown.print(allocator, "\n\n**Provenance:** {s}", .{prov});
    }

    try collector.facts.append(allocator, .{
        .line = if (token.line > 0) token.line - 1 else 0,
        .start = if (token.column > 0) token.column - 1 else 0,
        .end = if (token.end_column > 0) token.end_column - 1 else @max(@as(usize, if (token.column > 0) token.column - 1 else 0) + 1, 1),
        .markdown = try markdown.toOwnedSlice(allocator),
    });
}

// The callable summary workflow now lives in the ownership owner. The body
// checker reaches it through these declaration relays: a host table cannot take
// an owner namespace value that depends on the owner being built.
fn unifyGenericBinding(
    context: *SemaContext,
    path: []const u8,
    program: ast.Program,
    current_module: []const u8,
    pattern: ast.TypeName,
    actual: semantic_types.TypeId,
    generic_params: []const ast.GenericParam,
    inferred: []?semantic_types.GenericArgument,
) SemaError!void {
    return BodyOwner.unifyGenericBinding(context, path, program, current_module, pattern, actual, generic_params, inferred);
}

fn resolveExplicitGenericArgs(
    context: *SemaContext,
    path: []const u8,
    program: ast.Program,
    current_module: []const u8,
    function: ast.Function,
    explicit_type_args: []const ast.TypeName,
) SemaError![]semantic_types.GenericArgument {
    return BodyOwner.resolveExplicitGenericArgs(context, path, program, current_module, function, explicit_type_args);
}

fn selectSliceViewMethod(
    context: *SemaContext,
    path: []const u8,
    program: ast.Program,
    current_module: []const u8,
    receiver_type: semantic_types.TypeId,
    writable: bool,
    token: lexer.Token,
) SemaError!?ast.Function {
    return BodyOwner.selectSliceViewMethod(context, path, program, current_module, receiver_type, writable, token);
}

fn typeStructField(
    context: *SemaContext,
    path: []const u8,
    program: ast.Program,
    current_module: []const u8,
    ty: semantic_types.TypeId,
    field_name: []const u8,
    field_token: lexer.Token,
) SemaError!body_owner.StructFieldAccess {
    return BodyOwner.typeStructField(context, path, program, current_module, ty, field_name, field_token);
}

fn typeUnionPayloadField(
    context: *SemaContext,
    path: []const u8,
    program: ast.Program,
    current_module: []const u8,
    ty: semantic_types.TypeId,
    field_name: []const u8,
    field_token: lexer.Token,
) SemaError!body_owner.UnionPayloadAccess {
    return BodyOwner.typeUnionPayloadField(context, path, program, current_module, ty, field_name, field_token);
}

const OwnershipTypeAnalysis = ownership_owner.TypeAnalysis(.{
    .SemaContext = SemaContext,
    .SemaError = SemaError,
    .LocalBinding = LocalBinding,
    .GlobalBinding = GlobalBinding,
    .TypedExpr = TypedExpr,
    .parseType = parseType,
    .trustedConcurrentResource = trustedConcurrentResource,
    .semanticExprMetadata = semanticExprMetadata,
    .recordExprMetadata = recordExprMetadata,
    .optionalEql = optionalEql,
    .BorrowEscapeRelation = BorrowEscapeRelation,
    .BorrowEscapeSummaryRelation = BorrowEscapeSummaryRelation,
    .BorrowSummaryParamFacts = BorrowSummaryParamFacts,
    .ResolvedAstFunction = ResolvedAstFunction,
    .BorrowSummarySolveContext = BorrowSummarySolveContext,
    .findAstFunction = findAstFunction,
    .parseTypeWithBindings = parseTypeWithBindings,
    .unifyGenericBinding = unifyGenericBinding,
    .resolveExplicitGenericArgs = resolveExplicitGenericArgs,
    .selectSliceViewMethod = selectSliceViewMethod,
    .typeStructField = typeStructField,
    .typeUnionPayloadField = typeUnionPayloadField,
    .transferActionForExpr = transferActionForExpr,
});
pub const resolvePlace = OwnershipTypeAnalysis.resolvePlace;
const lowerImplicitHandoff = OwnershipTypeAnalysis.lowerImplicitHandoff;
const rejectProjectedResourceTransferForTypedValue = OwnershipTypeAnalysis.rejectProjectedResourceTransferForTypedValue;
const markLocalHandedOff = OwnershipTypeAnalysis.markLocalHandedOff;
const markCheckedNamedHandoff = OwnershipTypeAnalysis.markCheckedNamedHandoff;
const rejectScopedAllocCallEscape = OwnershipTypeAnalysis.rejectScopedAllocCallEscape;
const rejectScopedAllocMutationEscape = OwnershipTypeAnalysis.rejectScopedAllocMutationEscape;
const exprCarriesScopedAlloc = OwnershipTypeAnalysis.exprCarriesScopedAlloc;
const exprCarriesScopedAllocAs = OwnershipTypeAnalysis.exprCarriesScopedAllocAs;
const borrowOriginToken = OwnershipTypeAnalysis.borrowOriginToken;
const emitUnavailableLocal = OwnershipTypeAnalysis.emitUnavailableLocal;
const emitScopedAllocEscape = OwnershipTypeAnalysis.emitScopedAllocEscape;
const emitCallBorrowEscape = OwnershipTypeAnalysis.emitCallBorrowEscape;
const expectMutableReceiver = OwnershipTypeAnalysis.expectMutableReceiver;
const expectMutablePlaceRoot = OwnershipTypeAnalysis.expectMutablePlaceRoot;
pub const queryPlaceRootBindings = OwnershipTypeAnalysis.queryPlaceRootBindings;
pub const querySummaryPlaceRootBindings = OwnershipTypeAnalysis.querySummaryPlaceRootBindings;
const queryViewSourceBorrowRoots = OwnershipTypeAnalysis.queryViewSourceBorrowRoots;
const placeRootProvenance = OwnershipTypeAnalysis.placeRootProvenance;
const ownershipSummary = OwnershipTypeAnalysis.ownershipSummary;
const provenanceSummary = OwnershipTypeAnalysis.provenanceSummary;
pub const ownershipClass = OwnershipTypeAnalysis.ownershipClass;
const finalizeAndRecordExprSemantics = OwnershipTypeAnalysis.finalizeAndRecordExprSemantics;
pub const typeMayCarryBorrowedProvenance = OwnershipTypeAnalysis.typeMayCarryBorrowedProvenance;
const rootedBorrowProvenanceForType = OwnershipTypeAnalysis.rootedBorrowProvenanceForType;
const rejectBorrowedProvenanceReturnEscape = OwnershipTypeAnalysis.rejectBorrowedProvenanceReturnEscape;
const rejectBorrowedProvenanceAssignmentEscape = OwnershipTypeAnalysis.rejectBorrowedProvenanceAssignmentEscape;
const rejectBorrowedProvenanceMutationEscape = OwnershipTypeAnalysis.rejectBorrowedProvenanceMutationEscape;
const emitOwnershipDiagnostic = OwnershipTypeAnalysis.emitOwnershipDiagnostic;
const provenanceRootToken = ownership_owner.provenanceRootToken;
pub const ownershipFeatures = OwnershipTypeAnalysis.ownershipFeatures;

fn typeIsOwnedForProtocol(context: *SemaContext, path: []const u8, program: ast.Program, current_module: []const u8, type_id: semantic_types.TypeId) SemaError!bool {
    return OwnershipTypeAnalysis.typeIsOwnedForProtocol(context, path, program, current_module, type_id);
}

const ResolvedAstFunction = declarations.ResolvedFunction;

fn findAstFunction(
    context: *SemaContext,
    program: ast.Program,
    requester_module: []const u8,
    owner: ?[]const u8,
    name: []const u8,
) ?ResolvedAstFunction {
    const instantiated_base_name: ?[]const u8 = if (owner) |owner_name|
        if (findInstantiatedStruct(context, owner_name)) |decl| decl.base_name else null
    else
        null;
    return declarations.findFunction(
        if (context.declarations.registry) |*registry| registry else null,
        program,
        resolutionPolicy(context),
        instantiated_base_name,
        requester_module,
        owner,
        name,
    );
}

const Lookup = declarations.Lookup(SemaContext);
const findStructInModule = Lookup.findStructInModule;

fn trustedConcurrentResource(context: *SemaContext, decl_id: identity.DeclId) bool {
    const registry = if (context.declarations.registry) |*value| value else return false;
    return concurrency.isTrustedResource(registry, decl_id);
}

const isBorrowProducingViewExpr = ownership_owner.isBorrowProducingViewExpr;

const checkedStoredBorrowDependency = OwnershipTypeAnalysis.checkedStoredBorrowDependency;
const borrowedPlaceDependencyForStoredValue = OwnershipTypeAnalysis.borrowedPlaceDependencyForStoredValue;

pub const provenanceOutlivesTarget = ownership_owner.provenanceOutlivesTarget;
pub const provenanceOutlivesScope = ownership_owner.provenanceOutlivesScope;
pub const provenanceCanEscapeFunction = ownership_owner.provenanceCanEscapeFunction;
pub const provenanceCanEscapeReturn = ownership_owner.provenanceCanEscapeReturn;

const localMutationTargetScopeDepth = OwnershipTypeAnalysis.localMutationTargetScopeDepth;
pub const accumulateLocalRootSetMutationProvenance = OwnershipTypeAnalysis.accumulateLocalRootSetMutationProvenance;
const accumulateBorrowRootMutationProvenance = OwnershipTypeAnalysis.accumulateBorrowRootMutationProvenance;
pub const recordMutationProvenance = OwnershipTypeAnalysis.recordMutationProvenance;

const findLiteralField = ownership_owner.findLiteralField;

pub const PlaceProjectionPath = ownership_owner.PlaceProjectionPath;

const BorrowedPlaceDependency = ownership_owner.BorrowedPlaceDependency;

pub const LocalBinding = struct {
    name: []const u8,
    is_failure_view: bool = false,
    constant_int_value: ?i128 = null,
    binding_id: ?identity.BindingId = null,
    binding_mode: sir.BindingMode = .owning,
    projected_place: ?sir.CheckedPlacePath = null,
    generic_shape: *const generic_shapes.Shape = &generic_shapes.unknown,
    generic_origin: ?GenericReceiverOrigin = null,
    declaration_token: ?lexer.Token = null,
    borrowed_place: BorrowedPlaceDependency,
    provenance: Provenance,
    type_id: semantic_types.TypeId,
    is_param: bool,
    is_mutable: bool,
    is_for_binding: bool,
    is_unavailable: bool,
    unavailable_at: ?lexer.Token = null,
    deferred_handoff_depth: ?usize = null,
    deferred_handoff_at: ?lexer.Token = null,
    projection_origin: ?*ast.Expr = null,
    is_scoped_alloc_value: bool,
    scoped_alloc_origin: ?*ast.Expr = null,
    scope_depth: usize,

    pub fn kind(self: LocalBinding, context: *SemaContext) sir.Type {
        return canonicalTypeKind(context, self.type_id);
    }

    pub fn canonicalTypeId(self: LocalBinding, _: *SemaContext) SemaError!semantic_types.TypeId {
        return self.type_id;
    }
};

fn declarationSpan(program: ast.Program, fallback_path: []const u8, module_name: []const u8, token: lexer.Token) diagnostics.SourceSpan {
    return diagnostics.SourceSpan.fromToken(moduleSourcePath(program, module_name, fallback_path), token);
}

const UnknownValueKind = enum { value, local, binding };

pub const GlobalBinding = struct {
    id: identity.DeclId,
    name: []const u8,
    owner: ?[]const u8 = null,
    module_name: []const u8,
    is_pub: bool,
    autoload: bool = false,
    is_mutable: bool,
    is_extern: bool = false,
    is_symbol_addr: bool = false,
    type_id: semantic_types.TypeId,
    init: ?*const sir.Expr = null,

    pub fn canonicalTypeId(self: GlobalBinding, _: *SemaContext) SemaError!semantic_types.TypeId {
        return self.type_id;
    }
};

pub const OwnershipClass = ownership_owner.OwnershipClass;

pub const NormalizedBorrowRoots = ownership_owner.NormalizedBorrowRoots;
pub const Provenance = ownership_owner.Provenance;

const TypedExpr = struct {
    expr: *sir.Expr,
    generic_shape: *const generic_shapes.Shape = &generic_shapes.unknown,
    generic_origin: ?GenericReceiverOrigin = null,
    type_id: semantic_types.TypeId,
    provenance: Provenance = .none(),
    value_semantics: value_semantics.ValueSemantics = .plainValue(),
    intrinsic_id: ?sir.IntrinsicId = null,

    pub fn canonicalTypeId(self: TypedExpr, _: *SemaContext) SemaError!semantic_types.TypeId {
        return self.type_id;
    }

    pub fn kind(self: TypedExpr, context: *SemaContext) sir.Type {
        return canonicalTypeKind(context, self.type_id);
    }
};

fn makeTypedExprFromId(expr: *sir.Expr, type_id: semantic_types.TypeId) TypedExpr {
    return makeTypedExprFromIdWithProvenance(expr, type_id, .none());
}

pub fn projectedReadValueSemantics(result_has_storage_lifetime: bool, result_may_carry_borrowed_provenance: bool) value_semantics.ValueSemantics {
    return ownership_owner.projectedReadValueSemantics(
        result_has_storage_lifetime,
        result_may_carry_borrowed_provenance,
    );
}

const BuiltinLenKind = type_resolution.BuiltinLenKind;
const BuiltinClearKind = type_resolution.BuiltinClearKind;
const BuiltinContainsKind = type_resolution.BuiltinContainsKind;
const TypeBuiltinInsertMethod = type_resolution.TypeBuiltinInsertMethod;
const TypeBuiltinReserveMethod = type_resolution.TypeBuiltinReserveMethod;
const TypeBuiltinPopMethod = type_resolution.TypeBuiltinPopMethod;

/// One `syntax.iter*` hook a `for` loop desugars into, with the concrete
/// declaration it resolves to and the specialization that instantiated it.
const IteratorHookSource = struct {
    role: sir.GeneratedIterationRole,
    declaration_id: identity.DeclId,
    result_type_id: semantic_types.TypeId,
    args: ?[]const semantic_types.GenericArgument = null,
};

pub const normalizedBindingRootsOverlap = OwnershipTypeAnalysis.normalizedBindingRootsOverlap;

const constIndexValue = ownership_owner.constIndexValue;
pub const placeProjectionPathFromExpr = ownership_owner.placeProjectionPathFromExpr;

pub const pathOverlapsMutation = OwnershipTypeAnalysis.pathOverlapsMutation;
pub const pathInvalidatesView = OwnershipTypeAnalysis.pathInvalidatesView;
const rejectLiveBorrowPlaceMutationConflict = OwnershipTypeAnalysis.rejectLiveBorrowPlaceMutationConflict;
const rejectLiveBorrowContainerMutationConflict = OwnershipTypeAnalysis.rejectLiveBorrowContainerMutationConflict;
const rejectLiveBorrowInvalidation = OwnershipTypeAnalysis.rejectLiveBorrowInvalidation;

const TypeParser = type_resolution.Parser(SemaContext, .{
    .struct_support = StructSpecializationSupport,
    .alias_support = AliasSpecializationSupport,
});
pub fn parseType(context: *SemaContext, path: []const u8, program: ast.Program, current_module: []const u8, type_name: ast.TypeName) SemaError!semantic_types.TypeId {
    return TypeParser.parseType(context, path, program, current_module, type_name);
}

pub fn parseCanonicalType(context: *SemaContext, path: []const u8, program: ast.Program, current_module: []const u8, type_name: ast.TypeName) SemaError!semantic_types.TypeId {
    return TypeParser.parseCanonicalType(context, path, program, current_module, type_name);
}

pub fn parseTypeWithBindings(
    context: *SemaContext,
    path: []const u8,
    program: ast.Program,
    current_module: []const u8,
    type_name: ast.TypeName,
    self_type: ?semantic_types.TypeId,
    generic_params: []const ast.GenericParam,
    generic_args: []const semantic_types.GenericArgument,
) SemaError!semantic_types.TypeId {
    return TypeParser.parseTypeWithBindings(context, path, program, current_module, type_name, self_type, generic_params, generic_args);
}

fn parseTypeDepth(
    context: *SemaContext,
    path: []const u8,
    program: ast.Program,
    current_module: []const u8,
    type_name: ast.TypeName,
    self_type: ?semantic_types.TypeId,
    generic_params: []const ast.GenericParam,
    generic_args: []const semantic_types.GenericArgument,
    depth: usize,
) SemaError!semantic_types.TypeId {
    return TypeParser.parseTypeDepth(context, path, program, current_module, type_name, self_type, generic_params, generic_args, depth);
}

const TypeExpectationOrigin = session.TypeExpectationOrigin;

pub fn initCanonicalTestProgram(context: *SemaContext, path: []const u8, program: ast.Program) !void {
    context.canonical.types = semantic_types.TypeInterner.init(std.testing.allocator);
    errdefer {
        context.canonical.types.?.deinit();
        context.canonical.types = null;
    }
    context.declarations.registry = try declarations.registration.build(std.testing.allocator, path, program);
    context.protocol_conformances = protocol_conformance.Registry.init(std.testing.allocator);
}

pub fn deinitCanonicalTestProgram(context: *SemaContext) void {
    context.generic.shapes.deinit();
    context.protocol_conformances.?.deinit();
    context.protocol_conformances = null;
    context.declarations.registry.?.deinit();
    context.declarations.registry = null;
    context.canonical.types.?.deinit();
    context.canonical.types = null;
}

pub fn initCanonicalTestTypes(context: *SemaContext) void {
    context.canonical.types = semantic_types.TypeInterner.init(std.testing.allocator);
}

pub fn deinitCanonicalTestTypes(context: *SemaContext) void {
    context.generic.shapes.deinit();
    context.canonical.types.?.deinit();
    context.canonical.types = null;
}

pub fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

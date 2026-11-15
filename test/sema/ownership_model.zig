const std = @import("std");
const compiler = @import("cyna").compiler;
const ast = compiler.ast;
const lexer = compiler.lexer;
const identity = compiler.identity;
const ownership = compiler.ownership;
const semantic_types = compiler.semantic_types;
const sema = compiler.sema;

const SemaContext = sema.SemaContext;
const LocalBinding = sema.LocalBinding;
const GlobalBinding = sema.GlobalBinding;
const PlaceProjectionPath = sema.PlaceProjectionPath;
const NormalizedBorrowRoots = sema.NormalizedBorrowRoots;
const Provenance = sema.Provenance;
const BorrowEscapeRelation = sema.BorrowEscapeRelation;
const BorrowRootQuery = sema.BorrowRootQuery;
const BorrowSummaryParamFacts = sema.BorrowSummaryParamFacts;
const BorrowSummarySolveContext = sema.BorrowSummarySolveContext;
const BorrowSummarySolver = sema.BorrowSummarySolver;
const canonical = sema.canonical;
const projectionPathEqual = ownership.projectionPathEqual;
const canonicalPrimitiveTypeId = canonical.primitiveType;
const canonicalInferredIntegerTypeId = canonical.inferredIntegerType;
const canonicalIntegerTypeId = canonical.integerType;
const canonicalRefTypeId = canonical.refType;
const canonicalSliceTypeId = canonical.sliceType;
const canonicalArrayTypeId = canonical.arrayType;
const canonicalDenseArrayTypeId = canonical.denseArrayType;
const canonicalTypeKind = canonical.sirType;
const canonicalTypeNode = canonical.typeNode;
const localBinding = sema.localBinding;
const optionalEql = sema.optionalEql;
const projectedReadValueSemantics = sema.projectedReadValueSemantics;
const typeMayCarryBorrowedProvenance = sema.typeMayCarryBorrowedProvenance;
const accumulateLocalRootSetMutationProvenance = sema.accumulateLocalRootSetMutationProvenance;
const borrowSummaryKeyEql = sema.borrowSummaryKeyEql;
const borrowSummaryKeyIsInCycle = sema.borrowSummaryKeyIsInCycle;
const cacheBorrowSummaryRelation = sema.cacheBorrowSummaryRelation;
const computeBorrowSummarySccs = sema.computeBorrowSummarySccs;
const lookupBorrowSummaryRelation = sema.lookupBorrowSummaryRelation;
const makeBorrowSummaryKey = sema.makeBorrowSummaryKey;
const markSummaryRootsToTargetRootSet = sema.markSummaryRootsToTargetRootSet;
const maybeRecordActiveBorrowSummaryDependency = sema.maybeRecordActiveBorrowSummaryDependency;
const normalizedBindingRootsOverlap = sema.normalizedBindingRootsOverlap;
const pathInvalidatesView = sema.pathInvalidatesView;
const pathOverlapsMutation = sema.pathOverlapsMutation;
const placeProjectionPathFromExpr = sema.placeProjectionPathFromExpr;
const provenanceCanEscapeFunction = sema.provenanceCanEscapeFunction;
const provenanceCanEscapeReturn = sema.provenanceCanEscapeReturn;
const provenanceOutlivesScope = sema.provenanceOutlivesScope;
const provenanceOutlivesTarget = sema.provenanceOutlivesTarget;
const queryPlaceRootBindings = sema.queryPlaceRootBindings;
const querySummaryPlaceRootBindings = sema.querySummaryPlaceRootBindings;
const recordBorrowSummaryDependency = sema.recordBorrowSummaryDependency;
const recordMutationProvenance = sema.recordMutationProvenance;
const resolvePlace = sema.resolvePlace;
const summaryExprBorrowSourceFlags = sema.summaryExprBorrowSourceFlags;
const initCanonicalTestTypes = sema.initCanonicalTestTypes;
const deinitCanonicalTestTypes = sema.deinitCanonicalTestTypes;

test "provenance scope escape helper is conservative for local and composite borrows" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    initCanonicalTestTypes(context);
    defer deinitCanonicalTestTypes(context);
    const byte_slice = try canonicalSliceTypeId(context, try canonicalIntegerTypeId(context, "u8"), false);
    const locals = [_]LocalBinding{
        blk: {
            var binding = try localBinding(context, "outer", byte_slice, false, false);
            binding.scope_depth = 0;
            break :blk binding;
        },
        blk: {
            var binding = try localBinding(context, "inner", byte_slice, false, false);
            binding.scope_depth = 2;
            break :blk binding;
        },
    };

    try std.testing.expect(provenanceOutlivesScope(&locals, Provenance.localValue("outer"), 0));
    try std.testing.expect(!provenanceOutlivesScope(&locals, Provenance.localValue("inner"), 0));
    try std.testing.expect(provenanceCanEscapeFunction(&locals, Provenance.paramValue("p")));
    try std.testing.expect(!provenanceCanEscapeFunction(&locals, Provenance.scopedAllocValue()));
    try std.testing.expect(!provenanceCanEscapeFunction(&locals, Provenance.paramOwnerValue("text")));
    try std.testing.expect(provenanceOutlivesTarget(&locals, Provenance.paramOwnerValue("text"), .{ .scope = 0 }));
    try std.testing.expect(!provenanceOutlivesTarget(&locals, Provenance.paramOwnerValue("text"), .global));

    const composite = Provenance.combine(Provenance.localValue("outer"), Provenance.paramValue("p"));
    try std.testing.expect(provenanceCanEscapeFunction(&locals, composite));

    const composite_locals = Provenance.combine(Provenance.localValue("outer"), Provenance.localValue("inner"));
    try std.testing.expect(!provenanceCanEscapeFunction(&locals, composite_locals));
}

test "return escape permits param-owner roots only for borrowed parameters" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    initCanonicalTestTypes(context);
    defer deinitCanonicalTestTypes(context);
    const inferred_int = try canonicalInferredIntegerTypeId(context);
    var text = try localBinding(context, "text", try canonicalPrimitiveTypeId(context, .string), true, true);
    text.is_param = true;
    var slot = try localBinding(context, "slot", try canonicalRefTypeId(context, inferred_int), false, true);
    slot.is_param = true;
    var view = try localBinding(context, "view", try canonicalSliceTypeId(context, inferred_int, false), false, true);
    view.is_param = true;
    const locals = [_]LocalBinding{ text, slot, view };

    try std.testing.expect(!provenanceCanEscapeReturn(context, &locals, Provenance.paramOwnerValue("text")));
    try std.testing.expect(provenanceCanEscapeReturn(context, &locals, Provenance.paramOwnerValue("slot")));
    try std.testing.expect(provenanceCanEscapeReturn(context, &locals, Provenance.paramOwnerValue("view")));
}

test "alias root helpers preserve local and parameter binding roots" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    initCanonicalTestTypes(context);
    defer deinitCanonicalTestTypes(context);
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
    var local = try localBinding(context, "item", try canonicalInferredIntegerTypeId(context), false, true);
    local.is_param = false;
    var param = try localBinding(context, "text", try canonicalPrimitiveTypeId(context, .string), true, true);
    param.is_param = true;
    const locals = [_]LocalBinding{ local, param };

    var local_name = ast.Expr{ .name = .{ .text = "item", .token = std.mem.zeroes(lexer.Token) } };
    const local_roots = queryPlaceRootBindings(context, empty_program, "", &.{}, &locals, &local_name);
    try std.testing.expect(local_roots.contains_local);
    try std.testing.expect(local_roots.precise_local_roots);
    try std.testing.expect(local_roots.local_root_count == 1);
    try std.testing.expect(optionalEql(local_roots.local_roots[0], "item"));

    var param_name = ast.Expr{ .name = .{ .text = "text", .token = std.mem.zeroes(lexer.Token) } };
    const param_roots = queryPlaceRootBindings(context, empty_program, "", &.{}, &locals, &param_name);
    try std.testing.expect(param_roots.contains_param_owner);
    try std.testing.expect(param_roots.precise_param_owner_roots);
    try std.testing.expect(param_roots.param_owner_root_count == 1);
    try std.testing.expect(optionalEql(param_roots.param_owner_roots[0], "text"));
}

test "normalized binding root overlap respects kind and name" {
    try std.testing.expect(normalizedBindingRootsOverlap(
        NormalizedBorrowRoots.localValue("item"),
        NormalizedBorrowRoots.localValue("item"),
    ));
    try std.testing.expect(!normalizedBindingRootsOverlap(
        NormalizedBorrowRoots.localValue("item"),
        NormalizedBorrowRoots.localValue("other"),
    ));
    try std.testing.expect(!normalizedBindingRootsOverlap(
        NormalizedBorrowRoots.localValue("item"),
        NormalizedBorrowRoots.paramOwnerValue("item"),
    ));

    const left_or_right = NormalizedBorrowRoots.combine(
        NormalizedBorrowRoots.localValue("left"),
        NormalizedBorrowRoots.localValue("right"),
    );
    try std.testing.expect(normalizedBindingRootsOverlap(
        left_or_right,
        NormalizedBorrowRoots.localValue("right"),
    ));
    try std.testing.expect(!normalizedBindingRootsOverlap(
        left_or_right,
        NormalizedBorrowRoots.localValue("other"),
    ));

    const first_or_second = NormalizedBorrowRoots.combine(
        NormalizedBorrowRoots.paramOwnerValue("first"),
        NormalizedBorrowRoots.paramOwnerValue("second"),
    );
    try std.testing.expect(normalizedBindingRootsOverlap(
        first_or_second,
        NormalizedBorrowRoots.paramOwnerValue("second"),
    ));
    try std.testing.expect(!normalizedBindingRootsOverlap(
        first_or_second,
        NormalizedBorrowRoots.paramOwnerValue("third"),
    ));

    var widened = NormalizedBorrowRoots.none();
    widened.contains_local = true;
    widened.addLocalRoot("a");
    widened.addLocalRoot("b");
    widened.addLocalRoot("c");
    widened.addLocalRoot("d");
    widened.addLocalRoot("e");
    try std.testing.expect(normalizedBindingRootsOverlap(
        widened,
        NormalizedBorrowRoots.localValue("unknown"),
    ));
}

test "normalized borrow roots widen to finite imprecision after local root saturation" {
    var roots = NormalizedBorrowRoots.none();
    roots.contains_local = true;
    roots.addLocalRoot("a");
    roots.addLocalRoot("b");
    roots.addLocalRoot("c");
    roots.addLocalRoot("d");
    try std.testing.expect(roots.precise_local_roots);
    try std.testing.expect(roots.local_root_count == 4);

    roots.addLocalRoot("e");
    try std.testing.expect(!roots.precise_local_roots);
    try std.testing.expect(roots.local_root_count == 0);
    try std.testing.expect(roots.contains_local);
}

test "mutation provenance propagates across composite local borrow roots" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    initCanonicalTestTypes(context);
    defer deinitCanonicalTestTypes(context);
    const int_slice = try canonicalSliceTypeId(context, try canonicalIntegerTypeId(context, "i32"), false);
    var locals = [_]LocalBinding{
        try localBinding(context, "left", int_slice, false, true),
        try localBinding(context, "right", int_slice, false, true),
    };
    const composite_roots = NormalizedBorrowRoots.combine(
        NormalizedBorrowRoots.localValue("left"),
        NormalizedBorrowRoots.localValue("right"),
    );
    const incoming = Provenance.paramValue("source");

    accumulateLocalRootSetMutationProvenance(&locals, composite_roots, incoming);

    try std.testing.expect(locals[0].provenance.toNormalizedBorrowRoots().contains_param);
    try std.testing.expect(optionalEql(locals[0].provenance.toNormalizedBorrowRoots().param_roots[0], "source"));
    try std.testing.expect(locals[1].provenance.toNormalizedBorrowRoots().contains_param);
    try std.testing.expect(optionalEql(locals[1].provenance.toNormalizedBorrowRoots().param_roots[0], "source"));
}

test "record mutation provenance uses normalized target root sets" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    initCanonicalTestTypes(context);
    defer deinitCanonicalTestTypes(context);
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
    const int_slice = try canonicalSliceTypeId(context, try canonicalIntegerTypeId(context, "i32"), false);
    var left = try localBinding(context, "left", int_slice, false, true);
    left.provenance = Provenance.localValue("left_source");
    var right = try localBinding(context, "right", int_slice, false, true);
    right.provenance = Provenance.localValue("right_source");
    var slot = try localBinding(context, "slot", try canonicalRefTypeId(context, int_slice), false, true);
    slot.provenance = Provenance.combine(Provenance.localValue("left"), Provenance.localValue("right"));
    slot.borrowed_place = .{
        .roots = slot.provenance.toNormalizedBorrowRoots(),
        .projection = PlaceProjectionPath.root(),
        .mode = .alias,
    };
    var locals = [_]LocalBinding{ left, right, slot };
    var slot_name = ast.Expr{ .name = .{ .text = "slot", .token = std.mem.zeroes(lexer.Token) } };
    const incoming = Provenance.paramValue("source");

    try recordMutationProvenance(context, empty_program, "", &.{}, &locals, &slot_name, incoming);

    try std.testing.expect(normalizedBindingRootsOverlap(locals[0].provenance.toNormalizedBorrowRoots(), incoming.toNormalizedBorrowRoots()));
    try std.testing.expect(normalizedBindingRootsOverlap(locals[1].provenance.toNormalizedBorrowRoots(), incoming.toNormalizedBorrowRoots()));
    try std.testing.expect(normalizedBindingRootsOverlap(locals[2].provenance.toNormalizedBorrowRoots(), incoming.toNormalizedBorrowRoots()));
}

test "borrow escape relation clone and equality preserve lattice state" {
    const allocator = std.testing.allocator;
    var relation = try BorrowEscapeRelation.init(allocator, 2);
    defer relation.deinit(allocator);

    relation.markReturnFrom(.{ .roots = NormalizedBorrowRoots.paramValue("left") });
    relation.markGlobalFrom(.{ .roots = NormalizedBorrowRoots.paramOwnerValue("text") });
    relation.markSinkFrom(1, .{ .roots = NormalizedBorrowRoots.localValue("item") });

    var cloned = try relation.clone(allocator);
    defer cloned.deinit(allocator);

    try std.testing.expect(BorrowEscapeRelation.eql(relation, cloned));

    cloned.markSinkFrom(0, .{ .roots = NormalizedBorrowRoots.temporaryValue() });
    try std.testing.expect(!BorrowEscapeRelation.eql(relation, cloned));
}

fn testAstFunction(name: []const u8) ast.Function {
    return .{
        .module_name = "pkg",
        .owner = null,
        .name = name,
        .type_params = &.{},
        .params = &.{},
        .return_type = null,
        .body = &.{},
        .is_pub = false,
        .is_extern = false,
        .is_export = false,
        .calling_convention = .cyna,
        .name_token = std.mem.zeroes(lexer.Token),
    };
}

fn testBorrowSummaryAllocationOwnership(allocator: std.mem.Allocator) !void {
    var context = SemaContext.init(allocator, .{});
    defer context.deinitAnalysisState();
    var function = testAstFunction("allocation_ownership");
    function.params = @constCast(&[_]ast.Param{.{
        .name = "value",
        .type_name = .{ .name = "i32", .args = &.{}, .token = std.mem.zeroes(lexer.Token) },
        .name_token = std.mem.zeroes(lexer.Token),
    }});
    const generic_args = &[_]semantic_types.GenericArgument{.{ .const_usize = 1 }};
    const ctx = BorrowSummarySolveContext{
        .context = &context,
        .allocator = allocator,
        .path = "test.cy",
        .program = std.mem.zeroes(ast.Program),
        .current_module = "pkg",
        .globals = &.{},
        .function = function,
        .generic_args = generic_args,
        .summary_key = makeBorrowSummaryKey(function, generic_args),
        .facts = try testBorrowSummaryFacts(allocator),
    };
    var summary = try BorrowSummarySolver.init(ctx).resolve();
    defer summary.deinit(allocator);
    var reused_ctx = ctx;
    reused_ctx.facts = try testBorrowSummaryFacts(allocator);
    var reused = try BorrowSummarySolver.init(reused_ctx).resolve();
    defer reused.deinit(allocator);
    try std.testing.expect(BorrowEscapeRelation.eql(summary.relation, reused.relation));
}

fn testBorrowSummaryFacts(allocator: std.mem.Allocator) !BorrowSummaryParamFacts {
    const type_ids = try allocator.alloc(semantic_types.TypeId, 1);
    errdefer allocator.free(type_ids);
    const source_flags = try allocator.alloc(bool, 1);
    errdefer allocator.free(source_flags);
    const sink_flags = try allocator.alloc(bool, 1);
    @memset(type_ids, @fromBackingInt(@intCast(0)));
    @memset(source_flags, false);
    @memset(sink_flags, false);
    return .{
        .source_type_ids = type_ids,
        .source_can_borrow = source_flags,
        .sink_is_ref = sink_flags,
    };
}

test "borrow summary construction releases partial allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testBorrowSummaryAllocationOwnership, .{});
}

test "borrow summary key distinguishes generic instantiations" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    context.canonical.types = semantic_types.TypeInterner.init(std.testing.allocator);
    defer {
        context.canonical.types.?.deinit();
        context.canonical.types = null;
    }
    const function = testAstFunction("pick");

    const inferred_int = try canonicalInferredIntegerTypeId(context);
    const slice_arg = semantic_types.GenericArgument{ .type = try canonicalSliceTypeId(context, inferred_int, false) };
    const int_arg = semantic_types.GenericArgument{ .type = inferred_int };
    const slice_key = makeBorrowSummaryKey(function, &.{slice_arg});
    const int_key = makeBorrowSummaryKey(function, &.{int_arg});
    const same_slice_key = makeBorrowSummaryKey(function, &.{slice_arg});

    try std.testing.expect(!try borrowSummaryKeyEql(context, slice_key, int_key));
    try std.testing.expect(try borrowSummaryKeyEql(context, slice_key, same_slice_key));
}

test "borrow summary lookup prefers cached relation over active approximation" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    const allocator = std.testing.allocator;
    const saved_active = context.borrow_summaries.active;
    const saved_cached = context.borrow_summaries.cached;
    context.borrow_summaries.active = .empty;
    context.borrow_summaries.cached = .empty;
    defer {
        for (context.borrow_summaries.active.items) |entry| entry.deinit(allocator);
        context.borrow_summaries.active.deinit(allocator);
        for (context.borrow_summaries.cached.items) |entry| entry.deinit(allocator);
        context.borrow_summaries.cached.deinit(allocator);
        context.borrow_summaries.active = saved_active;
        context.borrow_summaries.cached = saved_cached;
    }

    const function = testAstFunction("pick");
    const key = makeBorrowSummaryKey(function, null);

    var active_relation = try BorrowEscapeRelation.init(allocator, 1);
    errdefer active_relation.deinit(allocator);
    active_relation.markReturnFrom(.{ .roots = NormalizedBorrowRoots.paramValue("active") });
    try context.borrow_summaries.active.append(allocator, .{
        .key = key,
        .relation = active_relation,
    });

    var cached_relation = try BorrowEscapeRelation.init(allocator, 1);
    errdefer cached_relation.deinit(allocator);
    cached_relation.markReturnFrom(.{ .roots = NormalizedBorrowRoots.paramValue("cached") });
    try context.borrow_summaries.cached.append(allocator, .{
        .key = .{
            .module_name = key.module_name,
            .owner = key.owner,
            .function_name = key.function_name,
            .generic_args = null,
        },
        .owned_generic_args = null,
        .relation = cached_relation,
    });

    var looked_up = try lookupBorrowSummaryRelation(context, allocator, key);
    defer if (looked_up) |result| result.relation.deinit(allocator);
    try std.testing.expect(looked_up != null);
    try std.testing.expect(looked_up.?.source == .cached);
    try std.testing.expect(optionalEql(looked_up.?.relation.return_roots.roots.singleRootName(), "cached"));
}

test "borrow summary lookup falls back to active approximation when cache is absent" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    const allocator = std.testing.allocator;
    const saved_active = context.borrow_summaries.active;
    const saved_cached = context.borrow_summaries.cached;
    context.borrow_summaries.active = .empty;
    context.borrow_summaries.cached = .empty;
    defer {
        for (context.borrow_summaries.active.items) |entry| entry.deinit(allocator);
        context.borrow_summaries.active.deinit(allocator);
        for (context.borrow_summaries.cached.items) |entry| entry.deinit(allocator);
        context.borrow_summaries.cached.deinit(allocator);
        context.borrow_summaries.active = saved_active;
        context.borrow_summaries.cached = saved_cached;
    }

    const function = testAstFunction("pick");
    const key = makeBorrowSummaryKey(function, null);

    var active_relation = try BorrowEscapeRelation.init(allocator, 1);
    errdefer active_relation.deinit(allocator);
    active_relation.markReturnFrom(.{ .roots = NormalizedBorrowRoots.paramValue("active") });
    try context.borrow_summaries.active.append(allocator, .{
        .key = key,
        .relation = active_relation,
    });

    var looked_up = try lookupBorrowSummaryRelation(context, allocator, key);
    defer if (looked_up) |result| result.relation.deinit(allocator);
    try std.testing.expect(looked_up != null);
    try std.testing.expect(looked_up.?.source == .active);
    try std.testing.expect(optionalEql(looked_up.?.relation.return_roots.roots.singleRootName(), "active"));
}

test "borrow summary cache update replaces prior relation in place" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    const allocator = std.testing.allocator;
    const saved_cached = context.borrow_summaries.cached;
    context.borrow_summaries.cached = .empty;
    defer {
        for (context.borrow_summaries.cached.items) |entry| entry.deinit(allocator);
        context.borrow_summaries.cached.deinit(allocator);
        context.borrow_summaries.cached = saved_cached;
    }

    const function = testAstFunction("pick");
    const key = makeBorrowSummaryKey(function, null);

    var first = try BorrowEscapeRelation.init(allocator, 1);
    defer first.deinit(allocator);
    first.markReturnFrom(.{ .roots = NormalizedBorrowRoots.paramValue("first") });
    try cacheBorrowSummaryRelation(context, allocator, key, null, first);

    var second = try BorrowEscapeRelation.init(allocator, 1);
    defer second.deinit(allocator);
    second.markReturnFrom(.{ .roots = NormalizedBorrowRoots.paramValue("second") });
    try cacheBorrowSummaryRelation(context, allocator, key, null, second);

    try std.testing.expect(context.borrow_summaries.cached.items.len == 1);
    try std.testing.expect(optionalEql(context.borrow_summaries.cached.items[0].relation.return_roots.roots.singleRootName(), "second"));
}

test "borrow summary dependency recording tracks active-to-requested edges" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    const allocator = std.testing.allocator;
    const saved_active = context.borrow_summaries.active;
    const saved_deps = context.borrow_summaries.dependencies;
    context.borrow_summaries.active = .empty;
    context.borrow_summaries.dependencies = .empty;
    defer {
        for (context.borrow_summaries.active.items) |entry| entry.deinit(allocator);
        context.borrow_summaries.active.deinit(allocator);
        for (context.borrow_summaries.dependencies.items) |edge| edge.deinit(allocator);
        context.borrow_summaries.dependencies.deinit(allocator);
        context.borrow_summaries.active = saved_active;
        context.borrow_summaries.dependencies = saved_deps;
    }

    const caller_fn = testAstFunction("caller");
    const callee_fn = testAstFunction("callee");

    var active_relation = try BorrowEscapeRelation.init(allocator, 0);
    errdefer active_relation.deinit(allocator);
    try context.borrow_summaries.active.append(allocator, .{
        .key = makeBorrowSummaryKey(caller_fn, null),
        .relation = active_relation,
    });

    try maybeRecordActiveBorrowSummaryDependency(context, allocator, makeBorrowSummaryKey(callee_fn, null));
    try std.testing.expect(context.borrow_summaries.dependencies.items.len == 1);
    try std.testing.expect(try borrowSummaryKeyEql(
        context,
        context.borrow_summaries.dependencies.items[0].from.view(),
        makeBorrowSummaryKey(caller_fn, null),
    ));
    try std.testing.expect(try borrowSummaryKeyEql(
        context,
        context.borrow_summaries.dependencies.items[0].to.view(),
        makeBorrowSummaryKey(callee_fn, null),
    ));
}

test "borrow summary SCCs collapse a cycle into one component" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    const allocator = std.testing.allocator;
    const saved_deps = context.borrow_summaries.dependencies;
    context.borrow_summaries.dependencies = .empty;
    defer {
        for (context.borrow_summaries.dependencies.items) |edge| edge.deinit(allocator);
        context.borrow_summaries.dependencies.deinit(allocator);
        context.borrow_summaries.dependencies = saved_deps;
    }

    const a_fn = testAstFunction("a");
    const b_fn = testAstFunction("b");
    const c_fn = testAstFunction("c");

    try recordBorrowSummaryDependency(context, allocator, makeBorrowSummaryKey(a_fn, null), makeBorrowSummaryKey(b_fn, null));
    try recordBorrowSummaryDependency(context, allocator, makeBorrowSummaryKey(b_fn, null), makeBorrowSummaryKey(c_fn, null));
    try recordBorrowSummaryDependency(context, allocator, makeBorrowSummaryKey(c_fn, null), makeBorrowSummaryKey(a_fn, null));

    const sccs = try computeBorrowSummarySccs(context, allocator);
    defer sccs.deinit(allocator);

    try std.testing.expect(sccs.components.len == 1);
    try std.testing.expect(sccs.components[0].members.len == 3);
}

test "borrow summary SCCs separate disconnected components" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    const allocator = std.testing.allocator;
    const saved_deps = context.borrow_summaries.dependencies;
    context.borrow_summaries.dependencies = .empty;
    defer {
        for (context.borrow_summaries.dependencies.items) |edge| edge.deinit(allocator);
        context.borrow_summaries.dependencies.deinit(allocator);
        context.borrow_summaries.dependencies = saved_deps;
    }

    const a_fn = testAstFunction("a");
    const b_fn = testAstFunction("b");
    const c_fn = testAstFunction("c");
    const d_fn = testAstFunction("d");

    try recordBorrowSummaryDependency(context, allocator, makeBorrowSummaryKey(a_fn, null), makeBorrowSummaryKey(b_fn, null));
    try recordBorrowSummaryDependency(context, allocator, makeBorrowSummaryKey(b_fn, null), makeBorrowSummaryKey(a_fn, null));
    try recordBorrowSummaryDependency(context, allocator, makeBorrowSummaryKey(c_fn, null), makeBorrowSummaryKey(d_fn, null));

    const sccs = try computeBorrowSummarySccs(context, allocator);
    defer sccs.deinit(allocator);

    try std.testing.expect(sccs.components.len == 3);
    var saw_pair = false;
    var saw_single_c = false;
    var saw_single_d = false;
    for (sccs.components) |component| {
        if (component.members.len == 2) saw_pair = true;
        if (component.members.len == 1 and optionalEql(component.members[0].view().function_name, "c")) saw_single_c = true;
        if (component.members.len == 1 and optionalEql(component.members[0].view().function_name, "d")) saw_single_d = true;
    }
    try std.testing.expect(saw_pair);
    try std.testing.expect(saw_single_c);
    try std.testing.expect(saw_single_d);
}

test "borrow summary cycle detection recognizes cyclic and acyclic keys" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    const allocator = std.testing.allocator;
    const saved_deps = context.borrow_summaries.dependencies;
    context.borrow_summaries.dependencies = .empty;
    defer {
        for (context.borrow_summaries.dependencies.items) |edge| edge.deinit(allocator);
        context.borrow_summaries.dependencies.deinit(allocator);
        context.borrow_summaries.dependencies = saved_deps;
    }

    const a_fn = testAstFunction("a");
    const b_fn = testAstFunction("b");
    const c_fn = testAstFunction("c");

    try recordBorrowSummaryDependency(context, allocator, makeBorrowSummaryKey(a_fn, null), makeBorrowSummaryKey(b_fn, null));
    try recordBorrowSummaryDependency(context, allocator, makeBorrowSummaryKey(b_fn, null), makeBorrowSummaryKey(a_fn, null));
    try recordBorrowSummaryDependency(context, allocator, makeBorrowSummaryKey(c_fn, null), makeBorrowSummaryKey(b_fn, null));

    try std.testing.expect(try borrowSummaryKeyIsInCycle(context, allocator, makeBorrowSummaryKey(a_fn, null)));
    try std.testing.expect(try borrowSummaryKeyIsInCycle(context, allocator, makeBorrowSummaryKey(b_fn, null)));
    try std.testing.expect(!(try borrowSummaryKeyIsInCycle(context, allocator, makeBorrowSummaryKey(c_fn, null))));
}

test "place path overlap handles root field index and container cases" {
    const root = PlaceProjectionPath.root();
    var left_field = PlaceProjectionPath.root();
    left_field.appendField("left");
    var right_field = PlaceProjectionPath.root();
    right_field.appendField("right");
    var nested_left_value = PlaceProjectionPath.root();
    nested_left_value.appendField("left");
    nested_left_value.appendField("value");
    var nested_right_value = PlaceProjectionPath.root();
    nested_right_value.appendField("right");
    nested_right_value.appendField("value");
    var idx0 = PlaceProjectionPath.root();
    idx0.appendIndex(0);
    var idx1 = PlaceProjectionPath.root();
    idx1.appendIndex(1);
    var idx_unknown = PlaceProjectionPath.root();
    idx_unknown.appendIndex(null);
    var idx0_container = PlaceProjectionPath.root();
    idx0_container.appendIndex(0);
    idx0_container.appendContainer();

    try std.testing.expect(pathOverlapsMutation(root, left_field));
    try std.testing.expect(pathOverlapsMutation(left_field, left_field));
    try std.testing.expect(!pathOverlapsMutation(left_field, right_field));
    try std.testing.expect(pathOverlapsMutation(nested_left_value, left_field));
    try std.testing.expect(!pathOverlapsMutation(nested_left_value, nested_right_value));
    try std.testing.expect(pathOverlapsMutation(idx0, idx0));
    try std.testing.expect(!pathOverlapsMutation(idx0, idx1));
    try std.testing.expect(pathOverlapsMutation(idx_unknown, idx1));
    try std.testing.expect(pathOverlapsMutation(idx0, idx0_container));
}

test "source place projections remain distinct beyond four steps" {
    const zero = std.mem.zeroes(lexer.Token);
    const names = [_][]const u8{ "a", "b", "c", "d", "e", "left" };
    var left_nodes: [7]ast.Expr = undefined;
    var right_nodes: [7]ast.Expr = undefined;
    left_nodes[0] = .{ .name = .{ .text = "root", .token = zero } };
    right_nodes[0] = .{ .name = .{ .text = "root", .token = zero } };
    for (names, 0..) |name, index| {
        left_nodes[index + 1] = .{ .field = .{ .object = &left_nodes[index], .field = name, .field_token = zero } };
        right_nodes[index + 1] = .{ .field = .{ .object = &right_nodes[index], .field = if (index == names.len - 1) "right" else name, .field_token = zero } };
    }
    const left = placeProjectionPathFromExpr(&left_nodes[6]);
    const right = placeProjectionPathFromExpr(&right_nodes[6]);
    try std.testing.expectEqual(@as(usize, 6), left.step_count);
    try std.testing.expect(!left.truncated);
    try std.testing.expect(!pathOverlapsMutation(left, right));
    try std.testing.expect(!projectionPathEqual(left, right));
    var changed = left;
    changed.appendContainer();
    try std.testing.expectEqual(@as(usize, 7), changed.step_count);
    try std.testing.expect(pathInvalidatesView(left, changed));
}

test "resolved places retain checked local and global root identities" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    initCanonicalTestTypes(context);
    defer deinitCanonicalTestTypes(context);
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
        .structs = &.{},
        .functions = &.{},
        .tests = &.{},
    };
    const type_id = try canonicalInferredIntegerTypeId(context);
    const outer = try localBinding(context, "slot", type_id, false, true);
    const inner = try localBinding(context, "slot", type_id, false, true);
    const locals = [_]LocalBinding{ outer, inner };
    var name = ast.Expr{ .name = .{ .text = "slot", .token = std.mem.zeroes(lexer.Token) } };
    const local_place = resolvePlace(context, program, "", &.{}, &locals, &name).?;
    try std.testing.expectEqual(inner.binding_id.?, local_place.root_binding_id.?);
    try std.testing.expect(local_place.root_global_id == null);

    const global_id: identity.DeclId = @fromBackingInt(@intCast(41));
    const globals = [_]GlobalBinding{.{
        .id = global_id,
        .name = "slot",
        .module_name = "",
        .is_pub = true,
        .is_mutable = false,
        .type_id = type_id,
    }};
    const global_place = resolvePlace(context, program, "", &globals, &.{}, &name).?;
    try std.testing.expectEqual(global_id, global_place.root_global_id.?);
    try std.testing.expect(global_place.root_binding_id == null);
}

test "view invalidation distinguishes replacement from descendant mutation" {
    const root = PlaceProjectionPath.root();
    var root_index = PlaceProjectionPath.root();
    root_index.appendIndex(0);
    var root_container = PlaceProjectionPath.root();
    root_container.appendContainer();
    var left = PlaceProjectionPath.root();
    left.appendField("left");
    var left_index = PlaceProjectionPath.root();
    left_index.appendField("left");
    left_index.appendIndex(0);
    var right = PlaceProjectionPath.root();
    right.appendField("right");

    try std.testing.expect(!pathInvalidatesView(root, root_index));
    try std.testing.expect(pathInvalidatesView(root, root_container));
    try std.testing.expect(pathInvalidatesView(left, left));
    try std.testing.expect(!pathInvalidatesView(left, left_index));
    try std.testing.expect(!pathInvalidatesView(left, right));
    try std.testing.expect(pathInvalidatesView(PlaceProjectionPath.conservativeRoot(), left_index));
}

test "summary place root helpers preserve parameter binding roots" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
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
    const zero = std.mem.zeroes(lexer.Token);
    const params = [_]ast.Param{
        .{
            .name = "slot",
            .type_name = .{ .array_len = null, .name = "&", .args = &.{}, .token = zero },
            .name_token = zero,
        },
    };
    var slot_name = ast.Expr{ .name = .{ .text = "slot", .token = zero } };
    const roots = querySummaryPlaceRootBindings(context, empty_program, "", &.{}, &params, &slot_name);
    try std.testing.expect(roots.contains_param_owner);
    try std.testing.expect(roots.precise_param_owner_roots);
    try std.testing.expect(roots.param_owner_root_count == 1);
    try std.testing.expect(optionalEql(roots.param_owner_roots[0], "slot"));
}

test "summary target sink marking handles composite parameter-owner roots" {
    const allocator = std.testing.allocator;
    const zero = std.mem.zeroes(lexer.Token);
    const params = [_]ast.Param{
        .{
            .name = "left",
            .type_name = .{ .array_len = null, .name = "&", .args = &.{}, .token = zero },
            .name_token = zero,
        },
        .{
            .name = "right",
            .type_name = .{ .array_len = null, .name = "&", .args = &.{}, .token = zero },
            .name_token = zero,
        },
        .{
            .name = "value",
            .type_name = .{ .array_len = null, .name = "[]", .args = &.{}, .token = zero },
            .name_token = zero,
        },
    };
    const sink_is_ref = [_]bool{ true, true, false };
    const target_roots = NormalizedBorrowRoots.combine(
        NormalizedBorrowRoots.combine(
            NormalizedBorrowRoots.paramOwnerValue("left"),
            NormalizedBorrowRoots.paramOwnerValue("right"),
        ),
        NormalizedBorrowRoots.paramOwnerValue("value"),
    );
    const source_roots = BorrowRootQuery{ .roots = NormalizedBorrowRoots.paramValue("source") };

    var relation = try BorrowEscapeRelation.init(allocator, params.len);
    defer relation.deinit(allocator);

    markSummaryRootsToTargetRootSet(&params, &sink_is_ref, target_roots, source_roots, &relation);

    try std.testing.expect(normalizedBindingRootsOverlap(relation.param_sink_roots[0].roots, source_roots.roots));
    try std.testing.expect(normalizedBindingRootsOverlap(relation.param_sink_roots[1].roots, source_roots.roots));
    try std.testing.expect(!relation.param_sink_roots[2].roots.hasAny());
}

test "summary borrow roots track view roots and ignore scalar index operands" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    initCanonicalTestTypes(context);
    defer deinitCanonicalTestTypes(context);

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
    const zero = std.mem.zeroes(lexer.Token);

    const params = [_]ast.Param{
        .{
            .name = "text",
            .type_name = .{ .array_len = null, .name = "string", .args = &.{}, .token = zero },
            .name_token = zero,
        },
        .{
            .name = "views",
            .type_name = .{ .array_len = null, .name = "[]", .args = &.{}, .token = zero },
            .name_token = zero,
        },
        .{
            .name = "idx",
            .type_name = .{ .array_len = null, .name = "i32", .args = &.{}, .token = zero },
            .name_token = zero,
        },
    };
    const param_types = [_]semantic_types.TypeId{
        try canonicalPrimitiveTypeId(context, .string),
        try canonicalSliceTypeId(context, try canonicalSliceTypeId(context, try canonicalIntegerTypeId(context, "i32"), false), false),
        try canonicalInferredIntegerTypeId(context),
    };
    const source_can_borrow = [_]bool{ false, true, false };

    var text_name = ast.Expr{ .name = .{ .text = "text", .token = zero } };
    var bytes_expr = ast.Expr{ .method_call = .{
        .object = &text_name,
        .method = "bytes",
        .method_token = zero,
        .type_args = &.{},
        .args = &.{},
    } };
    var text_roots = [_]bool{ false, false, false };
    try summaryExprBorrowSourceFlags(context, "", empty_program, "", &bytes_expr, &params, &param_types, &source_can_borrow, &text_roots);
    try std.testing.expect(text_roots[0]);
    try std.testing.expect(!text_roots[1]);
    try std.testing.expect(!text_roots[2]);
}

test "nested aggregate accessors preserve borrowed child shape" {
    var sema_context = SemaContext.init(std.testing.allocator, .{});
    const context = &sema_context;
    initCanonicalTestTypes(context);
    defer deinitCanonicalTestTypes(context);
    const u8_type = try canonicalIntegerTypeId(context, "u8");
    const slice = try canonicalSliceTypeId(context, u8_type, false);
    const dense_array_of_slices = try canonicalDenseArrayTypeId(context, slice);
    const array_of_dense_arrays = try canonicalArrayTypeId(context, 2, dense_array_of_slices);

    const reconstructed_dense_array = canonicalTypeNode(context, array_of_dense_arrays).array.item;
    try std.testing.expect(canonicalTypeKind(context, reconstructed_dense_array) == .dense_array);
    const reconstructed_slice = canonicalTypeNode(context, reconstructed_dense_array).dense_array;
    try std.testing.expect(canonicalTypeKind(context, reconstructed_slice) == .slice);
    try std.testing.expectEqual(u8_type, canonicalTypeNode(context, reconstructed_slice).slice.item);
}

test "projected read semantics distinguish borrow-carrying results" {
    try std.testing.expect(projectedReadValueSemantics(false, false).category == .value);
    try std.testing.expect(projectedReadValueSemantics(false, false).ownership == .plain);
    try std.testing.expect(projectedReadValueSemantics(false, true).category == .borrowed_projection);
    try std.testing.expect(projectedReadValueSemantics(false, true).ownership == .borrowed);
    try std.testing.expect(projectedReadValueSemantics(true, false).category == .borrowed_projection);
}

test "provenance combine preserves single roots and marks composites" {
    const local_a = Provenance.localValue("a");
    const local_a_again = Provenance.localValue("a");
    const param_b = Provenance.paramValue("b");
    const local_c = Provenance.localValue("c");

    const same = Provenance.combine(local_a, local_a_again);
    try std.testing.expect(same.singleRootKind() == .local);
    try std.testing.expect(same.hasBorrow());
    try std.testing.expect(optionalEql(same.singleRootName(), "a"));
    try std.testing.expect(same.localRootCount() == 1);
    try std.testing.expect(optionalEql(same.localRootAt(0), "a"));

    const composite = Provenance.combine(local_a, param_b);
    try std.testing.expect(composite.singleRootKind() == .composite);
    try std.testing.expect(composite.containsLocalRoots());
    try std.testing.expect(composite.containsParamRoots());
    try std.testing.expect(composite.hasPreciseLocalRoots());
    try std.testing.expect(composite.localRootCount() == 1);

    const multi_local = Provenance.combine(local_a, local_c);
    try std.testing.expect(multi_local.singleRootKind() == .composite);
    try std.testing.expect(multi_local.hasPreciseLocalRoots());
    try std.testing.expect(multi_local.localRootCount() == 2);
    try std.testing.expect(optionalEql(multi_local.localRootAt(0), "a"));
    try std.testing.expect(optionalEql(multi_local.localRootAt(1), "c"));
}

test "type borrowed provenance detects borrowed carriers recursively" {
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

    const inferred_int = try canonicalInferredIntegerTypeId(context);
    const byte_slice = try canonicalSliceTypeId(context, try canonicalIntegerTypeId(context, "u8"), false);
    try std.testing.expect(!(try typeMayCarryBorrowedProvenance(context, "", empty_program, "", inferred_int)));
    try std.testing.expect(!(try typeMayCarryBorrowedProvenance(context, "", empty_program, "", try canonicalPrimitiveTypeId(context, .string))));
    try std.testing.expect(try typeMayCarryBorrowedProvenance(context, "", empty_program, "", byte_slice));
    try std.testing.expect(try typeMayCarryBorrowedProvenance(context, "", empty_program, "", try canonicalRefTypeId(context, inferred_int)));
    try std.testing.expect(try typeMayCarryBorrowedProvenance(context, "", empty_program, "", try canonicalArrayTypeId(context, 2, byte_slice)));
    try std.testing.expect(try typeMayCarryBorrowedProvenance(context, "", empty_program, "", try canonicalDenseArrayTypeId(context, byte_slice)));
}

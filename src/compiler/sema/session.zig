const std = @import("std");
const identity = @import("identity.zig");
const semantic_types = @import("types.zig");
const ast = @import("../parser/ast.zig");
const diagnostics = @import("../diagnostics.zig");
const lexer = @import("../lexer/lexer.zig");
const sir = @import("sir.zig");
const generics = @import("generics.zig");
const generic_shapes = generics.shapes;
const target_info = @import("../target.zig");

pub const CanonicalAliasBinding = struct {
    decl_id: identity.DeclId,
    type_id: semantic_types.TypeId,
    is_distinct: bool,
};

pub const CanonicalGenericAliasBinding = struct {
    decl_id: identity.DeclId,
    args: []semantic_types.GenericArgument,
    type_id: semantic_types.TypeId,
};

/// Canonical types and aliases share one lifetime: aliases refer to interner
/// IDs and must be released before the interner goes away.
pub const CanonicalState = struct {
    types: ?semantic_types.TypeInterner = null,
    aliases: std.ArrayListUnmanaged(CanonicalAliasBinding) = .empty,
    generic_aliases: std.ArrayListUnmanaged(CanonicalGenericAliasBinding) = .empty,

    pub fn prepareInterner(self: *CanonicalState, allocator: std.mem.Allocator) error{OutOfMemory}!void {
        if (self.types) |*interner| interner.deinit();
        self.types = semantic_types.TypeInterner.init(allocator);
        errdefer {
            self.types.?.deinit();
            self.types = null;
        }
        inline for (.{ semantic_types.Primitive.void, .c_void, .bool, .rune, .string, .c_str }) |primitive| {
            _ = self.types.?.intern(.{ .primitive = primitive }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidTypeId => unreachable,
            };
        }
    }

    pub fn deinitGenericAliases(self: *CanonicalState, allocator: std.mem.Allocator) void {
        for (self.generic_aliases.items) |binding| allocator.free(binding.args);
        self.generic_aliases.deinit(allocator);
        self.generic_aliases = .empty;
    }

    pub fn deinitAliases(self: *CanonicalState, allocator: std.mem.Allocator) void {
        self.aliases.deinit(allocator);
        self.aliases = .empty;
        self.deinitGenericAliases(allocator);
    }

    pub fn deinitInterner(self: *CanonicalState) void {
        if (self.types) |*interner| interner.deinit();
        self.types = null;
    }
};

/// Source and generated declaration identities live for one semantic build.
pub const DeclarationState = struct {
    registry: ?identity.Registry = null,
    next_binding_id: u64 = 0,

    pub fn prepare(self: *DeclarationState) void {
        self.next_binding_id = 0;
    }

    pub fn deinitRegistry(self: *DeclarationState) void {
        if (self.registry) |*registry| registry.deinit();
        self.registry = null;
    }
};

/// Temporary IDs and owned generated strings contribute to the final SIR.
/// The module takes the strings only after `toOwnedSlice` succeeds.
pub const OutputState = struct {
    next_temporary_id: u64 = 0,
    generated_strings: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn prepare(self: *OutputState) void {
        self.next_temporary_id = 0;
        self.generated_strings = .empty;
    }

    pub fn deinitFailedOutputs(self: *OutputState, allocator: std.mem.Allocator) void {
        for (self.generated_strings.items) |value| allocator.free(value);
        self.generated_strings.deinit(allocator);
        self.generated_strings = .empty;
    }
};

/// Definition-site diagnostic retained for replay to the caller.
pub const GenericAdmissionFailure = struct {
    path: []const u8,
    token: lexer.Token,
    code: diagnostics.DiagnosticCode,
    message: []const u8,
    labels: []const diagnostics.Label,
    help: ?[]const u8,

    pub fn deinit(self: *const GenericAdmissionFailure, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        if (self.labels.len > 0) allocator.free(self.labels);
        if (self.help) |help| allocator.free(help);
    }
};

/// Source method use keyed by declaration and call-site position.
pub const MethodUseKey = struct {
    declaration_id: identity.DeclId,
    offset: usize,
};

/// Declared-contract stand-in for a generic binder method use.
pub const GenericContractFunction = struct {
    receiver: semantic_types.TypeId,
    protocol: identity.DeclId,
    method: identity.DeclId,
    decl_id: identity.DeclId,
    name: []const u8,
    return_type: semantic_types.TypeId,
};

/// Join recorded for a placeholder type the definition-site body interned.
pub const DeferredShape = struct {
    type_id: semantic_types.TypeId,
    shape: *const generic_shapes.Shape,
};

pub const InstantiatedStructField = struct {
    name: []const u8,
    type_id: semantic_types.TypeId,
    default_value: ?*ast.Expr = null,
    is_pub: bool,
};

pub const InstantiatedStructDecl = struct {
    id: ?identity.DeclId,
    base_decl_id: ?identity.DeclId,
    name: []const u8,
    base_name: []const u8,
    module_name: []const u8,
    layout: ast.StructLayout,
    is_shared_value: bool = false,
    is_owned_value: bool = false,
    is_sync_resource: bool = false,
    type_args: []semantic_types.GenericArgument,
    fields: []InstantiatedStructField,

    pub fn deinit(self: InstantiatedStructDecl, allocator: std.mem.Allocator) void {
        allocator.free(self.type_args);
        allocator.free(self.fields);
    }
};

/// Definition-site admission and specialization state. Checked requirements
/// and instantiated output transfer only after the final SIR validates.
pub const GenericState = struct {
    method_use_records: std.ArrayListUnmanaged(sir.GenericRequirement) = .empty,
    method_use_index: std.AutoHashMapUnmanaged(MethodUseKey, u32) = .empty,
    generic_contract_functions: std.ArrayListUnmanaged(sir.Function) = .empty,
    generic_contract_index: std.ArrayListUnmanaged(GenericContractFunction) = .empty,
    generic_definition_bodies: std.ArrayListUnmanaged(sir.Function) = .empty,
    definition_site_deferred_counter: u32 = 0,
    deferred_shapes: std.ArrayListUnmanaged(DeferredShape) = .empty,
    generic_definition_structs: std.ArrayListUnmanaged(sir.StructDecl) = .empty,
    generic_admission_failure: ?GenericAdmissionFailure = null,
    next_generated_use_id: u32 = 1,
    shapes: generic_shapes.Store = .{},
    instantiated_structs: std.ArrayListUnmanaged(InstantiatedStructDecl) = .empty,
    instantiated_functions: std.ArrayListUnmanaged(sir.Function) = .empty,

    pub fn deinitShapes(self: *GenericState) void {
        self.shapes.deinit();
    }

    pub fn prepareInstantiated(self: *GenericState) void {
        self.instantiated_structs = .empty;
        self.instantiated_functions = .empty;
    }

    pub fn deinitDeferredShapes(self: *GenericState, allocator: std.mem.Allocator) void {
        self.deferred_shapes.deinit(allocator);
        self.deferred_shapes = .empty;
    }

    pub fn transferInstantiatedFunctions(self: *GenericState, allocator: std.mem.Allocator, target: *std.ArrayListUnmanaged(sir.Function)) error{OutOfMemory}!void {
        // appendSlice either transfers all function values or none of them.
        try target.appendSlice(allocator, self.instantiated_functions.items);
        self.instantiated_functions.deinit(allocator);
        self.instantiated_functions = .empty;
    }

    pub fn deinitInstantiatedStructs(self: *GenericState, allocator: std.mem.Allocator) void {
        for (self.instantiated_structs.items) |decl| decl.deinit(allocator);
        self.instantiated_structs.deinit(allocator);
        self.instantiated_structs = .empty;
    }

    /// Called after the module has retained its own requirement records.
    pub fn finishCheckedRequirements(self: *GenericState, allocator: std.mem.Allocator) void {
        self.method_use_records.deinit(allocator);
        self.method_use_records = .empty;
        for (self.generic_definition_bodies.items) |function| function.deinit(allocator);
        self.generic_definition_bodies.deinit(allocator);
        self.generic_definition_bodies = .empty;
        self.generic_definition_structs.deinit(allocator);
        self.generic_definition_structs = .empty;
        self.deinitDeferredShapes(allocator);
        for (self.generic_contract_functions.items) |function| {
            allocator.free(function.name);
            function.deinit(allocator);
        }
        self.generic_contract_functions.deinit(allocator);
        self.generic_contract_functions = .empty;
        self.generic_contract_index.deinit(allocator);
        self.generic_contract_index = .empty;
        self.method_use_index.deinit(allocator);
        self.method_use_index = .empty;
    }

    pub fn deinitFailedOutputs(self: *GenericState, allocator: std.mem.Allocator) void {
        for (self.instantiated_structs.items) |decl| decl.deinit(allocator);
        self.instantiated_structs.deinit(allocator);
        self.instantiated_structs = .empty;
        for (self.instantiated_functions.items) |function| function.deinit(allocator);
        self.instantiated_functions.deinit(allocator);
        self.instantiated_functions = .empty;
        for (self.generic_definition_bodies.items) |function| function.deinit(allocator);
        self.generic_definition_bodies.deinit(allocator);
        self.generic_definition_bodies = .empty;
        for (self.generic_contract_functions.items) |function| {
            allocator.free(function.name);
            function.deinit(allocator);
        }
        self.generic_contract_functions.deinit(allocator);
        self.generic_contract_functions = .empty;
        for (self.generic_definition_structs.items) |decl| decl.deinit(allocator);
        self.generic_definition_structs.deinit(allocator);
        self.generic_definition_structs = .empty;
        self.generic_contract_index.deinit(allocator);
        self.generic_contract_index = .empty;
        self.method_use_records.deinit(allocator);
        self.method_use_records = .empty;
        self.method_use_index.deinit(allocator);
        self.method_use_index = .empty;
    }
};

/// The summary relation and worklist are supplied by the ownership workflow.
/// Session owns their per-build storage without importing that workflow.
pub fn BorrowSummaryState(
    comptime Worklist: type,
    comptime Active: type,
    comptime Cached: type,
    comptime Dependency: type,
) type {
    return struct {
        active_worklist: ?*Worklist = null,
        active: std.ArrayListUnmanaged(Active) = .empty,
        cached: std.ArrayListUnmanaged(Cached) = .empty,
        dependencies: std.ArrayListUnmanaged(Dependency) = .empty,

        pub fn prepare(self: *@This()) void {
            self.active_worklist = null;
            self.active = .empty;
            self.cached = .empty;
            self.dependencies = .empty;
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            for (self.active.items) |entry| entry.deinit(allocator);
            self.active.deinit(allocator);
            for (self.cached.items) |entry| entry.deinit(allocator);
            self.cached.deinit(allocator);
            for (self.dependencies.items) |edge| edge.deinit(allocator);
            self.dependencies.deinit(allocator);
        }
    };
}

pub const BuildOptions = struct {
    target: ?[]const u8 = null,
    test_friend: ?TestFriend = null,
    diagnostic_context: diagnostics.Context = .{ .destination = .discard },
    timing_session: ?*@import("../session.zig").CompilationSession = null,
    slice_view_normalizations: ?*std.ArrayListUnmanaged(SliceViewNormalization) = null,
    index_cast_normalizations: ?*std.ArrayListUnmanaged(IndexCastNormalization) = null,
    literal_cast_normalizations: ?*std.ArrayListUnmanaged(IndexCastNormalization) = null,
};

pub const SliceViewNormalization = struct {
    module_name: []const u8,
    method_offset: usize,
};

pub const IndexCastNormalization = struct {
    module_name: []const u8,
    cast_offset: usize,
    target_end_offset: usize,
};

pub const TestFriend = struct {
    test_module: []const u8,
    production_module: []const u8,
};

pub fn FunctionContext(comptime LocalBinding: type) type {
    return struct {
        pub const SwitchYieldContext = struct {
            parent: ?*SwitchYieldContext = null,
            expected_type_id: ?semantic_types.TypeId = null,
            result_type_id: ?semantic_types.TypeId = null,
            value_required: bool = false,
            scope_depth: usize = 0,
            scoped_alloc_depth: usize = 0,
            provenance: @TypeOf(@as(LocalBinding, undefined).provenance) = .none(),
        };

        active_locals: ?*std.ArrayListUnmanaged(LocalBinding) = null,
        active_switch_yield: ?*SwitchYieldContext = null,
        unchecked_depth: usize = 0,
        scoped_alloc_depth: usize = 0,
        scoped_alloc_region_depth: ?usize = null,
        block_depth: usize = 0,
        loop_depth: usize = 0,
        /// Return type of the innermost function body currently being lowered.
        current_return_type: ?semantic_types.TypeId = null,
        forbidden_capture_locals: ?[]const LocalBinding = null,
        forbidden_capture_is_lambda: bool = false,
        arrow_capture_records: ?*std.ArrayListUnmanaged(LocalBinding) = null,
        arrow_capture_env_name: ?[]const u8 = null,
        arrow_capture_env_type_name: ?[]const u8 = null,
        arrow_capture_env_decl_id: ?identity.DeclId = null,
        current_generic_params: []const ast.GenericParam = &.{},
        current_generic_args: []const semantic_types.GenericArgument = &.{},
        active_isolated_function: ?*const ast.Function = null,
        active_source_decl_id: ?identity.DeclId = null,
        active_return_decl_id: ?identity.DeclId = null,
        expected_return_token: ?lexer.Token = null,
        expected_return_path: ?[]const u8 = null,
        expected_type_origin: ?TypeExpectationOrigin = null,
        /// Set while lowering a function expression whose return type is a
        /// placeholder: every lowered `return` joins the shape it yields, so the
        /// call site reads the join the body produced rather than a syntax walk.
        deferred_return_join: ?*const generic_shapes.Shape = null,
    };
}

pub const SemanticHoverFact = struct {
    line: usize,
    start: usize,
    end: usize,
    markdown: []const u8,

    pub fn deinit(self: SemanticHoverFact, allocator: std.mem.Allocator) void {
        allocator.free(self.markdown);
    }
};

pub const SemanticHoverCollector = struct {
    module_name: []const u8,
    facts: *std.ArrayListUnmanaged(SemanticHoverFact),
};

pub const TypeExpectationOrigin = struct {
    path: []const u8,
    token: lexer.Token,
    message: []const u8,
};

pub const ReturnResolution = union(enum) {
    in_progress,
    resolved: semantic_types.TypeId,
};

/// Per-compilation state. Support supplies concrete types owned by recursive
/// workflows; this module owns their storage and lifecycle without importing
/// the workflow modules. No runtime service table is retained.
pub fn Context(comptime Support: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        generic: GenericState = .{},
        thread_boundary_frames: ?*std.ArrayListUnmanaged(Support.ThreadFrame) = null,
        diagnostic_context: diagnostics.Context = .{ .destination = .discard },
        options: BuildOptions,
        abi_layout: target_info.AbiLayout,
        semantic_hover: ?SemanticHoverCollector = null,
        output: OutputState = .{},
        anonymous_function_counter: usize = 0,
        canonical: CanonicalState = .{},
        expr_metadata: std.ArrayListUnmanaged(sir.ExprMetadataEntry) = .empty,
        expr_metadata_index: std.AutoHashMapUnmanaged(*const sir.Expr, usize) = .empty,
        return_resolutions: std.AutoHashMapUnmanaged(identity.DeclId, ReturnResolution) = .empty,
        borrow_summaries: BorrowSummaryState(Support.Worklist, Support.ActiveSummary, Support.CachedSummary, Support.SummaryDependency) = .{},
        declarations: DeclarationState = .{},
        generic_scopes: ?Support.GenericScopeRegistry = null,
        protocol_conformances: ?Support.ProtocolConformanceRegistry = null,
        function_state: FunctionContext(Support.Local) = .{},

        pub fn init(allocator: std.mem.Allocator, options: BuildOptions) Self {
            var context: Self = .{
                .allocator = allocator,
                .options = options,
                .abi_layout = target_info.abiLayout(options.target),
            };
            context.diagnostic_context = options.diagnostic_context;
            context.diagnostic_context.default_code = .semantic_invalid;
            return context;
        }

        pub fn prepare(self: *Self) error{ OutOfMemory, SemanticFailed }!void {
            const allocator = self.allocator;
            self.generic.deinitShapes();
            try self.canonical.prepareInterner(allocator);

            self.function_state = .{};
            self.declarations.prepare();
            self.output.prepare();
            self.borrow_summaries.prepare();
            self.generic.prepareInstantiated();
            for (self.expr_metadata.items) |entry| if (entry.metadata.checked_place_projections) |projections| allocator.free(projections);
            self.expr_metadata.deinit(allocator);
            self.expr_metadata = .empty;
            self.expr_metadata_index.deinit(allocator);
            self.expr_metadata_index = .empty;
            self.return_resolutions.deinit(allocator);
            self.return_resolutions = .empty;
            self.anonymous_function_counter = 0;
            self.canonical.deinitAliases(allocator);
            self.deinitIdentityRegistry();
            self.deinitProtocolConformances();
            self.protocol_conformances = Support.ProtocolConformanceRegistry.init(allocator);
        }

        pub fn deinitAnalysisState(self: *Self) void {
            self.borrow_summaries.deinit(self.allocator);
        }

        pub fn deinitCanonicalState(self: *Self) void {
            const allocator = self.allocator;
            self.generic.deinitShapes();
            self.canonical.deinitAliases(allocator);
            self.expr_metadata_index.deinit(allocator);
            self.expr_metadata_index = .empty;
            self.return_resolutions.deinit(allocator);
            self.return_resolutions = .empty;
            self.canonical.deinitInterner();
            self.deinitProtocolConformances();
        }

        pub fn deinitFailedOutputs(self: *Self) void {
            const allocator = self.allocator;
            self.output.deinitFailedOutputs(allocator);
            self.generic.deinitFailedOutputs(allocator);
            for (self.expr_metadata.items) |entry| if (entry.metadata.checked_place_projections) |projections| allocator.free(projections);
            self.expr_metadata.deinit(allocator);
            self.expr_metadata = .empty;
        }

        pub fn deinitIdentityRegistry(self: *Self) void {
            if (self.generic_scopes) |*registry| registry.deinit();
            self.generic_scopes = null;
            self.declarations.deinitRegistry();
        }

        fn deinitProtocolConformances(self: *Self) void {
            if (self.protocol_conformances) |*registry| registry.deinit();
            self.protocol_conformances = null;
        }
    };
}

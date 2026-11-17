const std = @import("std");
const lexer = @import("../lexer/token.zig");

pub const Program = struct {
    source: []const u8,
    tokens: []const lexer.Token,
    imports: []ImportDecl,
    module_infos: []ModuleInfo,
    globals: []Global,
    asm_consts: []AsmConst,
    aliases: []TypeAlias,
    enums: []EnumDecl,
    unions: []UnionDecl,
    protocols: []ProtocolDecl,
    impls: []ImplDecl,
    structs: []StructDecl,
    functions: []Function,
    tests: []InlineTest,

    pub fn deinit(self: Program, allocator: std.mem.Allocator) void {
        for (self.imports) |decl| decl.deinit(allocator);
        allocator.free(self.imports);
        for (self.module_infos) |info| info.deinit(allocator);
        allocator.free(self.module_infos);
        for (self.globals) |global| global.deinit(allocator);
        allocator.free(self.globals);
        for (self.asm_consts) |asm_const| asm_const.deinit(allocator);
        allocator.free(self.asm_consts);
        for (self.aliases) |alias| alias.deinit(allocator);
        allocator.free(self.aliases);
        for (self.enums) |decl| decl.deinit(allocator);
        allocator.free(self.enums);
        for (self.unions) |decl| decl.deinit(allocator);
        allocator.free(self.unions);
        for (self.protocols) |decl| decl.deinit(allocator);
        allocator.free(self.protocols);
        for (self.impls) |decl| decl.deinit(allocator);
        allocator.free(self.impls);
        for (self.structs) |decl| decl.deinit(allocator);
        allocator.free(self.structs);
        for (self.functions) |function| function.deinit(allocator);
        allocator.free(self.functions);
        for (self.tests) |inline_test| inline_test.deinit(allocator);
        allocator.free(self.tests);
    }
};

pub const ModuleInfo = struct {
    name: []const u8,
    source_path: []const u8 = "",
    autoload: bool = false,
    /// Set only by the package loader for modules shipped with the compiler.
    /// Source text cannot grant itself this authority.
    compiler_owned: bool = false,
    imports: []ImportDecl,

    pub fn deinit(self: ModuleInfo, allocator: std.mem.Allocator) void {
        for (self.imports) |decl| decl.deinit(allocator);
        allocator.free(self.imports);
    }
};

pub const ImportItem = struct {
    name: []const u8,
    local_name: ?[]const u8,
    name_token: lexer.Token,

    pub fn deinit(self: ImportItem, allocator: std.mem.Allocator) void {
        if (self.local_name) |local_name| allocator.free(local_name);
    }
};

pub const ImportDecl = struct {
    path: []const u8,
    is_root_package: bool = false,
    local_name: ?[]const u8 = null,
    items: []ImportItem,
    path_token: lexer.Token,

    pub fn deinit(self: ImportDecl, allocator: std.mem.Allocator) void {
        if (self.local_name) |local_name| allocator.free(local_name);
        for (self.items) |item| item.deinit(allocator);
        allocator.free(self.items);
        allocator.free(self.path);
    }
};

pub const TypeAlias = struct {
    module_name: []const u8,
    name: []const u8,
    type_params: []GenericParam,
    target: TypeName,
    is_pub: bool,
    is_distinct: bool,
    name_token: lexer.Token,

    pub fn deinit(self: TypeAlias, allocator: std.mem.Allocator) void {
        for (self.type_params) |param| param.deinit(allocator);
        allocator.free(self.type_params);
        self.target.deinit(allocator);
    }
};

pub const Global = struct {
    module_name: []const u8,
    owner: ?[]const u8 = null,
    is_mutable: bool,
    is_pub: bool,
    is_extern: bool = false,
    calling_convention: CallingConvention = .cyna,
    name: []const u8,
    abi_name: ?[]const u8 = null,
    type_name: ?TypeName,
    init: ?*Expr,
    owns_name: bool = false,
    name_token: lexer.Token,

    pub fn deinit(self: Global, allocator: std.mem.Allocator) void {
        if (self.owns_name) allocator.free(self.name);
        if (self.type_name) |type_name| type_name.deinit(allocator);
        if (self.init) |init| init.destroy(allocator);
    }
};

pub const AsmConst = struct {
    module_name: []const u8,
    name: []const u8,
    abi_name: ?[]const u8 = null,
    type_name: TypeName,
    init: *Expr,
    name_token: lexer.Token,

    pub fn deinit(self: AsmConst, allocator: std.mem.Allocator) void {
        self.type_name.deinit(allocator);
        self.init.destroy(allocator);
    }
};

pub const SliceFlags = packed struct(u8) {
    is_const: bool = false,
    item_is_optional: bool = false,
    _padding: u6 = 0,
};

pub const TypeName = struct {
    is_const_value_arg: bool = false,
    is_inline_error_union: bool = false,
    is_inferred_result_return: bool = false,
    const_value: ?usize = null,
    is_ref: bool = false,
    ref_is_const: bool = false,
    is_owned: bool = false,
    is_raw: bool = false,
    raw_is_const: bool = false,
    is_volatile_raw: bool = false,
    raw_target: ?*TypeName = null,
    is_optional: bool = false,
    is_function: bool = false,
    is_arrow_callable: bool = false,
    is_slice: bool = false,
    slice_flags: SliceFlags = .{},
    array_len: ?usize = null,
    array_len_name: ?[]const u8 = null,
    array_len_token: ?lexer.Token = null,
    module_name: ?[]const u8 = null,
    owns_module_name: bool = false,
    name: []const u8,
    args: []TypeName,
    function_calling_convention: CallingConvention = .cyna,
    function_params: []TypeName = &.{},
    function_return_type: ?*TypeName = null,
    token: lexer.Token,

    pub fn deinit(self: TypeName, allocator: std.mem.Allocator) void {
        if (self.raw_target) |target| {
            target.deinit(allocator);
            allocator.destroy(target);
        }
        if (self.owns_module_name) {
            if (self.module_name) |module_name| allocator.free(module_name);
        }
        for (self.args) |arg| arg.deinit(allocator);
        allocator.free(self.args);
        for (self.function_params) |param| param.deinit(allocator);
        allocator.free(self.function_params);
        if (self.function_return_type) |return_type| {
            return_type.deinit(allocator);
            allocator.destroy(return_type);
        }
    }
};

pub const GenericParam = struct {
    name: []const u8,
    constraint: ?TypeName,
    extra_constraints: []TypeName = &.{},
    name_token: lexer.Token,
    is_const_value: bool = false,

    pub fn deinit(self: GenericParam, allocator: std.mem.Allocator) void {
        if (self.constraint) |constraint| constraint.deinit(allocator);
        for (self.extra_constraints) |constraint| constraint.deinit(allocator);
        if (self.extra_constraints.len != 0) allocator.free(self.extra_constraints);
    }
};

pub const EnumDecl = struct {
    module_name: []const u8,
    name: []const u8,
    layout: EnumLayout,
    repr_name: ?[]const u8 = null,
    cases: []EnumCase,
    is_pub: bool,
    owns_name: bool = false,
    name_token: lexer.Token,

    pub fn deinit(self: EnumDecl, allocator: std.mem.Allocator) void {
        if (self.owns_name) allocator.free(self.name);
        allocator.free(self.cases);
    }
};

pub const EnumCase = struct {
    name: []const u8,
    value: ?i64,
    name_token: lexer.Token,
};

pub const EnumLayout = enum {
    normal,
    c,
    flags,
};

pub const UnionLayout = enum {
    normal,
    c,
};

pub const UnionKind = enum {
    named_cases,
    type_union,
};

pub const UnionDecl = struct {
    module_name: []const u8,
    name: []const u8,
    layout: UnionLayout,
    kind: UnionKind = .named_cases,
    fields: []UnionField,
    variants: []TypeName = &.{},
    is_pub: bool,
    name_token: lexer.Token,

    pub fn deinit(self: UnionDecl, allocator: std.mem.Allocator) void {
        for (self.fields) |field| field.deinit(allocator);
        allocator.free(self.fields);
        for (self.variants) |variant| variant.deinit(allocator);
        allocator.free(self.variants);
    }
};

pub const ProtocolDecl = struct {
    module_name: []const u8,
    name: []const u8,
    associated_types: []AssociatedTypeDecl,
    methods: []ProtocolMethod,
    is_pub: bool,
    name_token: lexer.Token,

    pub fn deinit(self: ProtocolDecl, allocator: std.mem.Allocator) void {
        allocator.free(self.associated_types);
        for (self.methods) |method| method.deinit(allocator);
        allocator.free(self.methods);
    }
};

pub const AssociatedTypeDecl = struct {
    name: []const u8,
    name_token: lexer.Token,
};

pub const AssociatedTypeBinding = struct {
    name: []const u8,
    type_name: TypeName,
    name_token: lexer.Token,

    pub fn deinit(self: AssociatedTypeBinding, allocator: std.mem.Allocator) void {
        self.type_name.deinit(allocator);
    }
};

pub const ProtocolMethod = struct {
    name: []const u8,
    params: []Param,
    return_type: ?TypeName,
    name_token: lexer.Token,

    pub fn deinit(self: ProtocolMethod, allocator: std.mem.Allocator) void {
        for (self.params) |param| param.deinit(allocator);
        allocator.free(self.params);
        if (self.return_type) |return_type| return_type.deinit(allocator);
    }
};

pub const ImplDecl = struct {
    module_name: []const u8,
    type_params: []GenericParam,
    /// Compiler-internal declaration namespace for protocol method bodies.
    /// Method identity must not collide with inherent methods or methods from
    /// another protocol implemented by the same type.
    method_owner: []const u8,
    type_name: TypeName,
    protocol_name: TypeName,
    associated_types: []AssociatedTypeBinding,
    methods: []Function,
    token: lexer.Token,

    pub fn deinit(self: ImplDecl, allocator: std.mem.Allocator) void {
        for (self.type_params) |param| param.deinit(allocator);
        allocator.free(self.type_params);
        self.type_name.deinit(allocator);
        self.protocol_name.deinit(allocator);
        for (self.associated_types) |binding| binding.deinit(allocator);
        allocator.free(self.associated_types);
        for (self.methods) |method| method.deinit(allocator);
        allocator.free(self.methods);
        allocator.free(self.method_owner);
    }
};

pub const UnionField = struct {
    name: []const u8,
    type_name: ?TypeName,
    name_token: lexer.Token,

    pub fn deinit(self: UnionField, allocator: std.mem.Allocator) void {
        if (self.type_name) |type_name| type_name.deinit(allocator);
    }
};

pub const StructLayout = enum {
    normal,
    c,
    @"packed",
};

pub const StructDecl = struct {
    module_name: []const u8,
    name: []const u8,
    type_params: []GenericParam,
    layout: StructLayout,
    fields: []FieldDecl,
    methods: []Function,
    is_pub: bool,
    is_concurrency_shareable: bool = false,
    is_shared_value: bool = false,
    is_owned_value: bool = false,
    owns_name: bool = false,
    name_token: lexer.Token,

    pub fn deinit(self: StructDecl, allocator: std.mem.Allocator) void {
        if (self.owns_name) allocator.free(self.name);
        for (self.type_params) |param| param.deinit(allocator);
        allocator.free(self.type_params);
        for (self.fields) |field| field.deinit(allocator);
        allocator.free(self.fields);
        for (self.methods) |method| method.deinit(allocator);
        allocator.free(self.methods);
    }
};

pub const FieldDecl = struct {
    name: []const u8,
    type_name: TypeName,
    default_value: ?*Expr = null,
    is_pub: bool,
    name_token: lexer.Token,

    pub fn deinit(self: FieldDecl, allocator: std.mem.Allocator) void {
        self.type_name.deinit(allocator);
        if (self.default_value) |value| value.destroy(allocator);
    }
};

pub const Param = struct {
    name: []const u8,
    type_name: TypeName,
    name_token: lexer.Token,

    pub fn deinit(self: Param, allocator: std.mem.Allocator) void {
        self.type_name.deinit(allocator);
    }
};

pub const CallingConvention = enum {
    cyna,
    c,
};

pub const SyntaxRole = enum {
    index,
    index_set,
    iter,
    iter_has_next,
    iter_next,
    iter_item,
};

pub const Function = struct {
    module_name: []const u8,
    owner: ?[]const u8,
    name: []const u8,
    abi_name: ?[]const u8 = null,
    /// Stable compiler operation named explicitly by compiler-owned source.
    /// The loader-provided module provenance, not this spelling, grants access.
    intrinsic_name: ?[]const u8 = null,
    intrinsic_token: ?lexer.Token = null,
    is_sequence_literal_factory: bool = false,
    is_slice_view: bool = false,
    syntax_role: ?SyntaxRole = null,
    type_params: []GenericParam,
    params: []Param,
    return_type: ?TypeName,
    body: []Stmt,
    is_pub: bool,
    is_extern: bool,
    is_export: bool,
    is_isolated: bool = false,
    is_concurrency_trusted_extern: bool = false,
    calling_convention: CallingConvention,
    name_token: lexer.Token,

    pub fn deinit(self: Function, allocator: std.mem.Allocator) void {
        for (self.type_params) |param| param.deinit(allocator);
        allocator.free(self.type_params);
        for (self.params) |param| param.deinit(allocator);
        allocator.free(self.params);
        if (self.return_type) |return_type| return_type.deinit(allocator);
        for (self.body) |stmt| stmt.deinit(allocator);
        allocator.free(self.body);
    }
};

pub const FunctionExprParam = struct {
    name: []const u8,
    type_name: ?TypeName,
    name_token: lexer.Token,

    pub fn deinit(self: FunctionExprParam, allocator: std.mem.Allocator) void {
        if (self.type_name) |type_name| type_name.deinit(allocator);
    }
};

pub const FunctionExpr = struct {
    calling_convention: CallingConvention,
    params: []FunctionExprParam,
    return_type: ?TypeName,
    body: []Stmt,
    token: lexer.Token,
    is_lambda: bool = false,

    pub fn deinit(self: FunctionExpr, allocator: std.mem.Allocator) void {
        for (self.params) |param| param.deinit(allocator);
        allocator.free(self.params);
        if (self.return_type) |return_type| return_type.deinit(allocator);
        for (self.body) |stmt| stmt.deinit(allocator);
        allocator.free(self.body);
    }
};

pub const InlineTest = struct {
    module_name: []const u8,
    name: []const u8,
    body: []Stmt,
    name_token: lexer.Token,

    pub fn deinit(self: InlineTest, allocator: std.mem.Allocator) void {
        for (self.body) |stmt| stmt.deinit(allocator);
        allocator.free(self.body);
    }
};

pub const Stmt = union(enum) {
    local: Local,
    discard: *Expr,
    assign: Assign,
    field_assign: FieldAssign,
    index_assign: IndexAssign,
    deref_assign: DerefAssign,
    deref_field_assign: DerefFieldAssign,
    using_alloc: UsingAlloc,
    unchecked: []Stmt,
    asm_stmt: AsmStmt,
    @"if": If,
    @"while": While,
    @"for": For,
    @"continue": lexer.Token,
    @"break": lexer.Token,
    @"switch": Switch,
    yield: Return,
    @"try": *Expr,
    @"defer": *Expr,
    drop: Drop,
    expr: *Expr,
    @"return": Return,

    pub fn deinit(self: Stmt, allocator: std.mem.Allocator) void {
        switch (self) {
            .local => |local| local.deinit(allocator),
            .discard => |expr| expr.destroy(allocator),
            .assign => |assign| assign.deinit(allocator),
            .field_assign => |assign| assign.deinit(allocator),
            .index_assign => |assign| assign.deinit(allocator),
            .deref_assign => |assign| assign.deinit(allocator),
            .deref_field_assign => |assign| assign.deinit(allocator),
            .using_alloc => |using_alloc| using_alloc.deinit(allocator),
            .unchecked => |body| {
                for (body) |stmt| stmt.deinit(allocator);
                allocator.free(body);
            },
            .asm_stmt => |asm_stmt| asm_stmt.deinit(allocator),
            .@"if" => |if_stmt| if_stmt.deinit(allocator),
            .@"while" => |while_stmt| while_stmt.deinit(allocator),
            .@"for" => |for_stmt| for_stmt.deinit(allocator),
            .@"continue", .@"break" => {},
            .@"switch" => |switch_stmt| switch_stmt.deinit(allocator),
            .yield => |yield_stmt| yield_stmt.deinit(allocator),
            .@"try" => |expr| expr.destroy(allocator),
            .@"defer" => |expr| expr.destroy(allocator),
            .drop => {},
            .expr => |expr| expr.destroy(allocator),
            .@"return" => |ret| ret.deinit(allocator),
        }
    }
};

pub const AsmStmt = struct {
    lines: []const []const u8,
    inputs: []const AsmInput,
    clobbers: []const AsmClobber,
    is_volatile: bool,
    token: lexer.Token,

    pub fn deinit(self: AsmStmt, allocator: std.mem.Allocator) void {
        for (self.inputs) |input| input.deinit(allocator);
        allocator.free(self.inputs);
        for (self.clobbers) |clobber| clobber.deinit(allocator);
        allocator.free(self.clobbers);
        allocator.free(self.lines);
    }
};

pub const AsmInput = struct {
    name: []const u8,
    constraint: AsmConstraint = .reg,
    value: *Expr,
    name_token: lexer.Token,

    pub fn deinit(self: AsmInput, allocator: std.mem.Allocator) void {
        self.value.destroy(allocator);
    }
};

pub const Return = struct {
    token: lexer.Token,
    value: ?*Expr,
    is_throw: bool = false,

    pub fn deinit(self: Return, allocator: std.mem.Allocator) void {
        if (self.value) |expr| expr.destroy(allocator);
    }
};

pub const Drop = struct {
    name: []const u8,
    name_token: lexer.Token,
};

pub const Local = struct {
    is_mutable: bool,
    name: []const u8,
    owns_name: bool = false,
    type_name: ?TypeName,
    init: *Expr,
    name_token: lexer.Token,

    pub fn deinit(self: Local, allocator: std.mem.Allocator) void {
        if (self.type_name) |type_name| type_name.deinit(allocator);
        self.init.destroy(allocator);
        if (self.owns_name) allocator.free(self.name);
    }
};

pub const Assign = struct {
    name: []const u8,
    value: *Expr,
    name_token: lexer.Token,

    pub fn deinit(self: Assign, allocator: std.mem.Allocator) void {
        self.value.destroy(allocator);
    }
};

pub const IndexAssign = struct {
    object: *Expr,
    index: *Expr,
    value: *Expr,
    token: lexer.Token,

    pub fn deinit(self: IndexAssign, allocator: std.mem.Allocator) void {
        self.object.destroy(allocator);
        self.index.destroy(allocator);
        self.value.destroy(allocator);
    }
};

pub const FieldAssign = struct {
    object: *Expr,
    fields: []const DerefFieldAssignStep,
    value: *Expr,
    token: lexer.Token,
    capture: ?AssignmentCapture = null,

    pub fn deinit(self: FieldAssign, allocator: std.mem.Allocator) void {
        self.object.destroy(allocator);
        allocator.free(self.fields);
        self.value.destroy(allocator);
    }
};

pub const AssignmentCapture = struct {
    name: []const u8,
    name_token: lexer.Token,
    is_mutable: bool,
};

pub const DerefAssign = struct {
    pointer: *Expr,
    value: *Expr,
    token: lexer.Token,

    pub fn deinit(self: DerefAssign, allocator: std.mem.Allocator) void {
        self.pointer.destroy(allocator);
        self.value.destroy(allocator);
    }
};

pub const DerefFieldAssign = struct {
    pointer: *Expr,
    fields: []const DerefFieldAssignStep,
    value: *Expr,
    token: lexer.Token,

    pub fn deinit(self: DerefFieldAssign, allocator: std.mem.Allocator) void {
        self.pointer.destroy(allocator);
        allocator.free(self.fields);
        self.value.destroy(allocator);
    }
};

pub const DerefFieldAssignStep = struct {
    field: []const u8,
    field_token: lexer.Token,
};

pub const UsingAlloc = struct {
    is_scoped: bool,
    allocator_expr: *Expr,
    body: []Stmt,
    token: lexer.Token,

    pub fn deinit(self: UsingAlloc, allocator: std.mem.Allocator) void {
        self.allocator_expr.destroy(allocator);
        for (self.body) |stmt| stmt.deinit(allocator);
        allocator.free(self.body);
    }
};

pub const If = struct {
    condition: *Expr,
    then_body: []Stmt,
    else_body: []Stmt,

    pub fn deinit(self: If, allocator: std.mem.Allocator) void {
        self.condition.destroy(allocator);
        for (self.then_body) |stmt| stmt.deinit(allocator);
        allocator.free(self.then_body);
        for (self.else_body) |stmt| stmt.deinit(allocator);
        allocator.free(self.else_body);
    }
};

pub const While = struct {
    condition: *Expr,
    body: []Stmt,

    pub fn deinit(self: While, allocator: std.mem.Allocator) void {
        self.condition.destroy(allocator);
        for (self.body) |stmt| stmt.deinit(allocator);
        allocator.free(self.body);
    }
};

pub const For = struct {
    name: []const u8,
    name_token: lexer.Token,
    iterable: *Expr,
    body: []Stmt,

    pub fn deinit(self: For, allocator: std.mem.Allocator) void {
        self.iterable.destroy(allocator);
        for (self.body) |stmt| stmt.deinit(allocator);
        allocator.free(self.body);
    }
};

pub const Switch = struct {
    value: *Expr,
    cases: []SwitchCase,
    has_else: bool,
    else_body: []Stmt,
    catch_propagate_unmatched: bool = false,
    catch_code_name: ?[]const u8 = null,
    catch_failure_name: ?[]const u8 = null,
    catch_fallback: bool = false,

    pub fn deinit(self: Switch, allocator: std.mem.Allocator) void {
        self.value.destroy(allocator);
        for (self.cases) |case| case.deinit(allocator);
        allocator.free(self.cases);
        for (self.else_body) |stmt| stmt.deinit(allocator);
        allocator.free(self.else_body);
    }
};

pub const SwitchCase = struct {
    type_name: ?[]const u8,
    case_name: []const u8,
    type_variant: ?TypeName = null,
    scalar_pattern: ?*Expr = null,
    payload_name: ?[]const u8,
    token: lexer.Token,
    body: []Stmt,

    pub fn deinit(self: SwitchCase, allocator: std.mem.Allocator) void {
        if (self.type_variant) |variant| variant.deinit(allocator);
        if (self.scalar_pattern) |pattern| pattern.destroy(allocator);
        for (self.body) |stmt| stmt.deinit(allocator);
        allocator.free(self.body);
    }
};

pub const BinaryOp = enum {
    add,
    wrap_add,
    sub,
    wrap_sub,
    mul,
    wrap_mul,
    div,
    mod,
    shl,
    shr,
    bit_and,
    bit_or,
    bit_xor,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    in,
    @"and",
    @"or",
};

pub const IsTestKind = enum {
    optional_some,
    optional_none,
    union_case,
};

pub const UnaryOp = enum {
    not,
    bit_not,
    negate,
    take,
};

pub const Expr = union(enum) {
    int: IntLiteral,
    float: FloatLiteral,
    rune: RuneLiteral,
    string: StringLiteral,
    interpolated_string: InterpolatedString,
    bool: BoolLiteral,
    none: lexer.Token,
    @"switch": Switch,
    name: Name,
    address_of: AddressOfExpr,
    @"try": TryExpr,
    deref: UnaryExpr,
    unary: Unary,
    is_test: IsTestExpr,
    cast: CastExpr,
    @"comptime": ComptimeExpr,
    binary: Binary,
    call: Call,
    method_call: MethodCall,
    function_expr: FunctionExpr,
    enum_case: EnumCaseExpr,
    union_case: UnionCaseExpr,
    slice_range: SliceRange,
    index: Index,
    array_literal: ArrayLiteral,
    sequence_repeat: SequenceRepeat,
    typed_sequence_literal: TypedSequenceLiteral,
    keyed_literal: KeyedLiteral,
    fixed_array_construct: FixedArrayConstruct,
    new_array: NewArray,
    new_sparse: NewSparse,
    new_owned: StructLiteral,
    struct_literal: StructLiteral,
    asm_expr: AsmExpr,
    field: FieldAccess,

    pub fn destroy(self: *Expr, allocator: std.mem.Allocator) void {
        self.deinit(allocator);
        allocator.destroy(self);
    }

    fn deinit(self: *Expr, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .int => {},
            .float => {},
            .rune => {},
            .string => |literal| if (literal.owns_text) allocator.free(literal.text),
            .interpolated_string => |interpolated| interpolated.deinit(allocator),
            .bool => {},
            .none => {},
            .@"switch" => |switch_expr| switch_expr.deinit(allocator),
            .name => {},
            .address_of => |address_of| address_of.expr.destroy(allocator),
            .@"try" => |try_expr| try_expr.expr.destroy(allocator),
            .deref => |deref| deref.expr.destroy(allocator),
            .unary => |unary| unary.expr.destroy(allocator),
            .is_test => |is_test| is_test.subject.destroy(allocator),
            .cast => |cast| {
                cast.subject.destroy(allocator);
                cast.target.deinit(allocator);
            },
            .@"comptime" => |ct| ct.expr.destroy(allocator),
            .binary => |binary| {
                binary.left.destroy(allocator);
                binary.right.destroy(allocator);
            },
            .call => |call| {
                for (call.type_args) |arg| arg.deinit(allocator);
                allocator.free(call.type_args);
                for (call.args) |arg| arg.deinit(allocator);
                allocator.free(call.args);
            },
            .method_call => |call| {
                call.object.destroy(allocator);
                for (call.type_args) |arg| arg.deinit(allocator);
                allocator.free(call.type_args);
                for (call.args) |arg| arg.deinit(allocator);
                allocator.free(call.args);
            },
            .function_expr => |function_expr| function_expr.deinit(allocator),
            .enum_case => {},
            .union_case => |case| {
                if (case.value) |value| value.destroy(allocator);
                if (case.throw_message) |message| if (message.owns_text) allocator.free(message.text);
            },
            .slice_range => |slice| {
                slice.object.destroy(allocator);
                if (slice.start) |start| start.destroy(allocator);
                if (slice.end) |end| end.destroy(allocator);
            },
            .index => |index| {
                index.object.destroy(allocator);
                index.index.destroy(allocator);
            },
            .array_literal => |literal| {
                for (literal.items) |item| item.destroy(allocator);
                allocator.free(literal.items);
            },
            .sequence_repeat => |repeat| {
                for (repeat.items) |item| item.destroy(allocator);
                allocator.free(repeat.items);
                repeat.count.destroy(allocator);
            },
            .typed_sequence_literal => |literal| {
                literal.target.deinit(allocator);
                for (literal.items) |item| item.destroy(allocator);
                allocator.free(literal.items);
            },
            .keyed_literal => |literal| {
                if (literal.target) |target| target.deinit(allocator);
                for (literal.entries) |entry| {
                    entry.key.destroy(allocator);
                    entry.value.destroy(allocator);
                }
                allocator.free(literal.entries);
            },
            .fixed_array_construct => |construct| {
                construct.item_type.deinit(allocator);
                for (construct.items) |item| item.destroy(allocator);
                allocator.free(construct.items);
            },
            .new_array => |new_array| {
                new_array.len.destroy(allocator);
                new_array.item_type.deinit(allocator);
            },
            .new_sparse => |new_sparse| {
                new_sparse.capacity.destroy(allocator);
                new_sparse.item_type.deinit(allocator);
            },
            .new_owned => |literal| {
                for (literal.type_args) |arg| arg.deinit(allocator);
                allocator.free(literal.type_args);
                for (literal.fields) |field| field.value.destroy(allocator);
                allocator.free(literal.fields);
            },
            .struct_literal => |literal| {
                for (literal.type_args) |arg| arg.deinit(allocator);
                allocator.free(literal.type_args);
                for (literal.fields) |field| field.value.destroy(allocator);
                allocator.free(literal.fields);
            },
            .asm_expr => |asm_expr| asm_expr.deinit(allocator),
            .field => |field| {
                field.object.destroy(allocator);
                if (field.owns_field) allocator.free(field.field);
            },
        }
    }
};

pub const AsmExpr = struct {
    result_type: TypeName,
    lines: []const []const u8,
    output: ?AsmOutput,
    inout: ?AsmInput,
    inputs: []const AsmInput,
    clobbers: []const AsmClobber,
    is_volatile: bool,
    token: lexer.Token,

    pub fn deinit(self: AsmExpr, allocator: std.mem.Allocator) void {
        self.result_type.deinit(allocator);
        if (self.inout) |inout| inout.deinit(allocator);
        for (self.inputs) |input| input.deinit(allocator);
        allocator.free(self.inputs);
        for (self.clobbers) |clobber| clobber.deinit(allocator);
        allocator.free(self.clobbers);
        allocator.free(self.lines);
    }
};

pub const AsmOutput = struct {
    name: []const u8,
    constraint: AsmConstraint = .reg,
    name_token: lexer.Token,
};

pub const AsmConstraint = enum {
    reg,
    tied_reg,
};

pub const AsmClobber = union(enum) {
    memory,
    flags,
    register: []const u8,

    pub fn deinit(self: AsmClobber, allocator: std.mem.Allocator) void {
        switch (self) {
            .register => |name| allocator.free(name),
            else => {},
        }
    }
};

pub const StringLiteral = struct {
    text: []const u8,
    token: lexer.Token,
    owns_text: bool = false,
};

pub const RuneLiteral = struct {
    value: u32,
    token: lexer.Token,
};

pub const InterpolationFormat = enum {
    direct,
    decimal,
    binary,
    octal,
    hex_lower,
    hex_upper,
};

pub const InterpolatedStringPart = union(enum) {
    literal: []const u8,
    hole: InterpolationHole,

    pub fn deinit(self: InterpolatedStringPart, allocator: std.mem.Allocator) void {
        switch (self) {
            .literal => |text| allocator.free(text),
            .hole => |hole| allocator.free(hole.fields),
        }
    }
};

pub const InterpolationHole = struct {
    base: Name,
    fields: []const Name,
    format: InterpolationFormat,
    token: lexer.Token,
};

pub const InterpolatedString = struct {
    parts: []const InterpolatedStringPart,
    token: lexer.Token,

    pub fn deinit(self: InterpolatedString, allocator: std.mem.Allocator) void {
        for (self.parts) |part| part.deinit(allocator);
        allocator.free(self.parts);
    }
};

pub const IntLiteral = struct {
    value: i64,
    unsigned_value: ?u64 = null,
    token: lexer.Token,
};

pub const FloatLiteral = struct {
    value: f64,
    token: lexer.Token,
};

pub const BoolLiteral = struct {
    value: bool,
    token: lexer.Token,
};

pub const Name = struct {
    text: []const u8,
    token: lexer.Token,
};

pub const AddressOfExpr = struct {
    expr: *Expr,
    token: lexer.Token,
};

pub const TryExpr = struct {
    expr: *Expr,
    token: lexer.Token,
};

pub const UnaryExpr = struct {
    expr: *Expr,
    token: lexer.Token,
};

pub const Binary = struct {
    op: BinaryOp,
    left: *Expr,
    right: *Expr,
};

pub const Unary = struct {
    op: UnaryOp,
    expr: *Expr,
};

pub const IsTestExpr = struct {
    subject: *Expr,
    kind: IsTestKind,
    case_name: ?[]const u8,
    capture_name: ?[]const u8,
    capture_token: ?lexer.Token = null,
    token: lexer.Token,
};

pub const CastExpr = struct {
    subject: *Expr,
    target: TypeName,
    fallible: bool,
    reinterpret: bool,
    token: lexer.Token,
};

pub const ComptimeExpr = struct {
    expr: *Expr,
    token: lexer.Token,
};

pub const Call = struct {
    owner: ?[]const u8,
    callee: []const u8,
    callee_token: lexer.Token,
    type_args: []TypeName,
    args: []CallArg,
};

pub const MethodCall = struct {
    object: *Expr,
    method: []const u8,
    method_token: lexer.Token,
    type_args: []TypeName,
    args: []CallArg,
};

pub const CallArg = union(enum) {
    value: *Expr,

    pub fn deinit(self: CallArg, allocator: std.mem.Allocator) void {
        switch (self) {
            .value => |expr| expr.destroy(allocator),
        }
    }
};

pub const EnumCaseExpr = struct {
    type_name: []const u8,
    case_name: []const u8,
    token: lexer.Token,
};

pub const UnionCaseExpr = struct {
    case_name: []const u8,
    value: ?*Expr,
    token: lexer.Token,
    is_synthetic_throw: bool = false,
    throw_message: ?StringLiteral = null,
};

pub const SliceRange = struct {
    object: *Expr,
    start: ?*Expr = null,
    end: ?*Expr = null,
    token: lexer.Token,
};

pub const Index = struct {
    object: *Expr,
    index: *Expr,
    token: lexer.Token,
};

pub const ArrayLiteral = struct {
    token: lexer.Token,
    items: []*Expr,
};

pub const SequenceRepeat = struct {
    token: lexer.Token,
    items: []*Expr,
    count: *Expr,
};

pub const TypedSequenceLiteral = struct {
    token: lexer.Token,
    target: TypeName,
    storage_capacity: ?usize = null,
    items: []*Expr,
};

pub const KeyedLiteral = struct {
    token: lexer.Token,
    target: ?TypeName = null,
    storage_capacity: ?usize = null,
    entries: []KeyedLiteralEntry,
};

pub const KeyedLiteralEntry = struct {
    key: *Expr,
    value: *Expr,
};

pub const FixedArrayConstruct = struct {
    token: lexer.Token,
    len: usize,
    item_type: TypeName,
    items: []*Expr,
};

pub const NewArray = struct {
    token: lexer.Token,
    len: *Expr,
    item_type: TypeName,
};

pub const NewSparse = struct {
    token: lexer.Token,
    capacity: *Expr,
    item_type: TypeName,
};

pub const StructLiteral = struct {
    type_name: ?[]const u8,
    type_args: []TypeName,
    type_token: lexer.Token,
    fields: []StructLiteralField,
};

pub const StructLiteralField = struct {
    name: []const u8,
    name_token: lexer.Token,
    value: *Expr,
};

pub const FieldAccess = struct {
    object: *Expr,
    field: []const u8,
    field_token: lexer.Token,
    owns_field: bool = false,
};

/// The token a span starts at. Every expression record carries its own token,
/// so diagnostic emitters can point at the expression they are reporting on
/// without walking the token stream.
pub fn firstExprToken(expr: *Expr) lexer.Token {
    return switch (expr.*) {
        .int => |literal| literal.token,
        .float => |literal| literal.token,
        .rune => |literal| literal.token,
        .string => |literal| literal.token,
        .interpolated_string => |interpolated| interpolated.token,
        .bool => |literal| literal.token,
        .none => |token| token,
        .@"switch" => |switch_expr| firstExprToken(switch_expr.value),
        .name => |name| name.token,
        .address_of => |address_of| address_of.token,
        .@"try" => |try_expr| try_expr.token,
        .deref => |deref| deref.token,
        .unary => |unary| firstExprToken(unary.expr),
        .binary => |binary| firstExprToken(binary.left),
        .call => |call| call.callee_token,
        .method_call => |call| firstExprToken(call.object),
        .function_expr => |function_expr| function_expr.token,
        .enum_case => |case| case.token,
        .union_case => |case| case.token,
        .is_test => |is_test| is_test.token,
        .cast => |cast| cast.token,
        .@"comptime" => |ct| ct.token,
        .slice_range => |slice| firstExprToken(slice.object),
        .index => |index| firstExprToken(index.object),
        .array_literal => |literal| literal.token,
        .sequence_repeat => |repeat| repeat.token,
        .typed_sequence_literal => |literal| literal.token,
        .fixed_array_construct => |construct| construct.token,
        .new_array => |new_array| new_array.token,
        .new_sparse => |new_sparse| new_sparse.token,
        .new_owned => |literal| literal.type_token,
        .struct_literal => |literal| literal.type_token,
        .keyed_literal => |literal| literal.token,
        .asm_expr => |asm_expr| asm_expr.token,
        .field => |field| firstExprToken(field.object),
    };
}

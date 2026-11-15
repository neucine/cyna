const std = @import("std");
const capability = @import("capability.zig");
const sir = @import("sema/sir.zig");
const diagnostics = @import("diagnostics.zig");

pub const Error = error{
    LowerInvariantViolation,
    BackendInvariantViolation,
};

pub const Phase = enum {
    sir_to_lir,
    lir_to_llvm,

    fn label(self: Phase) []const u8 {
        return switch (self) {
            .sir_to_lir => "SIR-to-LIR lowering",
            .lir_to_llvm => "LIR-to-LLVM emission",
        };
    }
};

pub fn message(buffer: []u8, phase: Phase, err: anyerror) ?[]const u8 {
    const detail = detailFor(phase, err) orelse return null;
    return std.fmt.bufPrint(
        buffer,
        "internal compiler error during {s}: {s} [{s}]",
        .{ phase.label(), detail, @errorName(err) },
    ) catch "internal compiler error";
}

pub fn diagnosticMessage(buffer: []u8, phase: Phase, err: anyerror) ?[]const u8 {
    return capability.message(err) orelse message(buffer, phase, err);
}

/// Preserve the distinction between an unsupported target and a compiler defect
/// in structured diagnostics, including failures without a source token.
pub fn emitFailure(context: diagnostics.Context, path: []const u8, phase: Phase, err: anyerror) !void {
    var buffer: [256]u8 = undefined;
    const internal = message(&buffer, phase, err);
    try context.emit(.{
        .code = if (internal != null) .internal_invariant else if (capability.message(err) != null) .capability else .legacy_unclassified,
        .path = path,
        .message = capability.message(err) orelse internal orelse @errorName(err),
    });
}

/// Revisit a failed SIR identity check only on the error path to recover the
/// source function and metadata entry without storing source spans in all SIR.
pub fn emitSirIdentityFailure(
    context: diagnostics.Context,
    module: sir.Module,
    source_map: anytype,
    fallback_path: []const u8,
    err: anyerror,
) !bool {
    switch (err) {
        error.InvalidBindingIdentity,
        error.InvalidTemporaryIdentity,
        error.InvalidCaptureIdentity,
        error.InvalidCheckedPlaceRoot,
        error.InvalidCheckedPlaceProjection,
        error.InvalidTypeIdentity,
        error.MissingExpressionMetadata,
        error.MissingCanonicalTypes,
        => {},
        else => return false,
    }
    var failure: sir.IdentityFailureContext = .{};
    const observed = blk: {
        module.verifyCompilerIdentitiesWithContext(&failure) catch |verify_err| break :blk verify_err;
        return false;
    };
    if (observed != err) return false;
    var message_buffer: [256]u8 = undefined;
    const detail = diagnosticMessage(&message_buffer, .sir_to_lir, err) orelse @errorName(err);
    const function = failure.function orelse {
        try context.emit(.{ .code = .internal_invariant, .path = fallback_path, .message = detail });
        return true;
    };
    var path = fallback_path;
    for (source_map) |entry| {
        if (std.mem.eql(u8, entry.module_name, function.module_name)) {
            path = entry.source_path;
            break;
        }
    }
    if (function.debug_token.line == 0) {
        try context.emit(.{ .code = .internal_invariant, .path = path, .message = detail });
    } else if (failure.metadata_index) |index| {
        try context.emitTokenWith(path, function.debug_token, .{ .code = .internal_invariant }, "{s} in `{s}` (expression metadata #{d}, {s})", .{ detail, function.name, index, failure.expression_kind orelse "unknown" });
    } else {
        try context.emitTokenWith(path, function.debug_token, .{ .code = .internal_invariant }, "{s} in `{s}`", .{ detail, function.name });
    }
    return true;
}

fn detailFor(phase: Phase, err: anyerror) ?[]const u8 {
    return switch (err) {
        error.InvalidIdentity => "resolved declaration or type identity is invalid",
        error.InvalidSir => "typed SIR violates a lowering precondition",
        error.MissingLocal => "typed SIR references a missing local binding",
        error.MissingResultContext => "result lowering has no active result context",
        error.UnterminatedBlock => if (phase == .sir_to_lir)
            "lowering produced an unterminated block"
        else
            "verified LIR contains an unterminated block",
        error.LowerInvariantViolation => "verified SIR state has no matching lowering invariant case",
        error.BackendInvariantViolation => "verified LIR state has no matching LLVM emission invariant case",

        error.DuplicateExpressionMetadata => "SIR contains duplicate expression metadata",
        error.InvalidExpressionMetadata => "SIR expression metadata is invalid",
        error.MissingExpressionMetadata => "SIR expression metadata is missing",
        error.InvalidSinkAction => "SIR contains an invalid ownership sink action",
        error.IncorrectIntrinsicIdentity => "SIR intrinsic identity does not match its operation",
        error.InvalidIntrinsicExpression => "SIR intrinsic expression is malformed",
        error.InvalidResultCaseIdentity => "SIR result-case identity is invalid",
        error.InvalidTestEntryIdentity => "SIR test-entry identity is invalid",
        error.MissingCanonicalTypes => "SIR has no canonical type graph",
        error.InvalidTypeIdentity => "SIR references an invalid canonical type identity",
        error.InvalidBindingIdentity => "SIR binding identity is invalid",
        error.InvalidTemporaryIdentity => "SIR temporary identity is invalid",
        error.InvalidCaptureIdentity => "SIR closure capture identity is invalid",
        error.InvalidCheckedPlaceRoot => "SIR checked place references an invalid root",
        error.InvalidCheckedPlaceProjection => "SIR checked place projection is invalid",

        error.InvalidTypeReference => "LIR references a missing type",
        error.InvalidTypeDefinition => "LIR contains an invalid type definition",
        error.InvalidGlobalType => "LIR global type is invalid",
        error.InvalidFunctionType => "LIR function type contract is invalid",
        error.InvalidFunctionStructure => "LIR function structure is invalid",
        error.InvalidBlockTarget => "LIR branch target is invalid",
        error.InvalidValueDefinition => "LIR value definition is invalid",
        error.InvalidValueReference => "LIR references a missing value",
        error.InvalidParameterReference => "LIR parameter reference is invalid",
        error.InvalidInlineAsm => "LIR inline-assembly tables are inconsistent",
        else => null,
    };
}

test "internal errors include phase detail and stable identity" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "internal compiler error during SIR-to-LIR lowering: SIR intrinsic identity does not match its operation [IncorrectIntrinsicIdentity]",
        message(&buffer, .sir_to_lir, error.IncorrectIntrinsicIdentity).?,
    );
    try std.testing.expectEqualStrings(
        "internal compiler error during LIR-to-LLVM emission: LIR references a missing value [InvalidValueReference]",
        message(&buffer, .lir_to_llvm, error.InvalidValueReference).?,
    );
    try std.testing.expect(message(&buffer, .lir_to_llvm, error.OutOfMemory) == null);
    try std.testing.expectEqualStrings(
        capability.message(error.BackendPackedFieldAddressUnsupported).?,
        diagnosticMessage(&buffer, .lir_to_llvm, error.BackendPackedFieldAddressUnsupported).?,
    );
}

test "path failures retain internal and capability diagnostic codes" {
    var sink = diagnostics.Sink.init(std.testing.allocator);
    defer sink.deinit();
    const context = diagnostics.Context.structured(&sink);
    try emitFailure(context, "sample.cy", .sir_to_lir, error.InvalidSir);
    try emitFailure(context, "sample.cy", .lir_to_llvm, error.BackendPackedFieldAddressUnsupported);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.internal_invariant, sink.records.items[0].code);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.capability, sink.records.items[1].code);
}

test "SIR identity failures retain the source function location" {
    const types_mod = @import("sema/types.zig");
    var types = types_mod.TypeInterner.init(std.testing.allocator);
    defer types.deinit();
    const int_type = try types.intern(.{ .integer = .{ .bits = 32, .signed = true } });
    var expr: sir.Expr = .{ .int = .{ .value = 1, .type_name = null } };
    const body = [_]sir.Stmt{.{ .expr = &expr }};
    const functions = [_]sir.Function{.{
        .module_name = "sample",
        .owner = null,
        .name = "broken",
        .params = &.{},
        .debug_token = .{ .tag = .identifier, .lexeme = "broken", .offset = 20, .end_offset = 26, .line = 3, .column = 4, .end_column = 10 },
        .body = &body,
    }};
    const metadata = [_]sir.ExprMetadataEntry{.{
        .expr = &expr,
        .metadata = .{ .type_id = int_type, .semantics = .plainValue(), .checked_place_root = .{ .binding = @fromBackingInt(@intCast(999)) } },
    }};
    const module: sir.Module = .{
        .canonical_types = types,
        .expr_metadata = &metadata,
        .globals = &.{},
        .enums = &.{},
        .unions = &.{},
        .structs = &.{},
        .functions = &functions,
    };
    var sink = diagnostics.Sink.init(std.testing.allocator);
    defer sink.deinit();
    const context = diagnostics.Context.structured(&sink);
    const source_map = [_]struct { module_name: []const u8, source_path: []const u8 }{
        .{ .module_name = "sample", .source_path = "sample.cy" },
    };
    try std.testing.expect(try emitSirIdentityFailure(context, module, &source_map, "fallback.cy", error.InvalidCheckedPlaceRoot));
    try std.testing.expectEqual(@as(usize, 1), sink.records.items.len);
    const record = sink.records.items[0];
    try std.testing.expectEqualStrings("sample.cy", record.path);
    try std.testing.expectEqual(@as(usize, 3), record.primary.?.line);
    try std.testing.expect(std.mem.indexOf(u8, record.message, "broken") != null);
    try std.testing.expect(std.mem.indexOf(u8, record.message, "expression metadata #0") != null);
}

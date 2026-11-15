const std = @import("std");
const lexer = @import("lexer/token.zig");

pub const Location = union(enum) {
    path,
    token: lexer.Token,
};

pub const Severity = enum {
    err,
    warning,
    information,
    hint,
};

pub const DiagnosticCode = enum {
    legacy_unclassified,
    parse_syntax,
    name_resolution,
    name_unknown_type,
    name_unknown_value,
    name_unknown_callable,
    name_unknown_module,
    name_ambiguous,
    duplicate_declaration,
    visibility,
    visibility_private,
    type_mismatch,
    generic_constraint,
    generic_arity,
    generic_inference,
    generic_argument_kind,
    ownership,
    ownership_borrow_escape,
    ownership_live_borrow_conflict,
    ownership_use_after_transfer,
    ownership_invalidation,
    ownership_scoped_escape,
    ownership_capture,
    ownership_cleanup,
    container_operation,
    sum_type_shape,
    abi_boundary,
    capability,
    semantic_invalid,
    diagnostic_limit_reached,
    internal_invariant,
};

pub const SourceSpan = struct {
    path: []const u8,
    start: usize,
    end: usize,
    line: usize,
    column: usize,
    end_column: usize,

    pub fn fromToken(path: []const u8, token: lexer.Token) SourceSpan {
        return .{
            .path = path,
            .start = token.offset,
            .end = token.end_offset,
            .line = token.line,
            .column = token.column,
            .end_column = token.end_column,
        };
    }
};

pub const LabelStyle = enum {
    primary,
    secondary,
};

pub const Label = struct {
    span: SourceSpan,
    message: []const u8,
    style: LabelStyle = .secondary,
};

pub const FixApplicability = enum {
    machine_applicable,
    maybe_incorrect,
    has_placeholders,
    unspecified,
};

pub const Fix = struct {
    span: SourceSpan,
    replacement: []const u8,
    applicability: FixApplicability = .unspecified,
};

pub const DiagnosticSpec = struct {
    code: DiagnosticCode = .legacy_unclassified,
    severity: Severity = .err,
    path: []const u8,
    message: []const u8,
    primary: ?SourceSpan = null,
    labels: []const Label = &.{},
    notes: []const []const u8 = &.{},
    help: ?[]const u8 = null,
    fixes: []const Fix = &.{},
};

pub const DiagnosticDetails = struct {
    code: DiagnosticCode = .legacy_unclassified,
    severity: Severity = .err,
    labels: []const Label = &.{},
    notes: []const []const u8 = &.{},
    help: ?[]const u8 = null,
    fixes: []const Fix = &.{},
};

pub const Diagnostic = struct {
    code: DiagnosticCode,
    severity: Severity,
    path: []const u8,
    location: Location,
    message: []const u8,
    primary: ?SourceSpan,
    labels: []Label,
    notes: [][]const u8,
    help: ?[]const u8,
    fixes: []Fix,

    pub fn asSpec(self: *const Diagnostic) DiagnosticSpec {
        return .{
            .code = self.code,
            .severity = self.severity,
            .path = self.path,
            .message = self.message,
            .primary = self.primary,
            .labels = self.labels,
            .notes = self.notes,
            .help = self.help,
            .fixes = self.fixes,
        };
    }

    pub fn deinit(self: Diagnostic, allocator: std.mem.Allocator) void {
        for (self.labels) |label| {
            allocator.free(label.span.path);
            allocator.free(label.message);
        }
        allocator.free(self.labels);
        for (self.notes) |note| allocator.free(note);
        allocator.free(self.notes);
        if (self.help) |help| allocator.free(help);
        for (self.fixes) |fix| {
            allocator.free(fix.span.path);
            allocator.free(fix.replacement);
        }
        allocator.free(self.fixes);
        allocator.free(self.path);
        allocator.free(self.message);
    }
};

pub const Record = Diagnostic;

pub const NormalizeOptions = struct {
    max_diagnostics: usize = 64,
};

pub const Sink = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayListUnmanaged(Record) = .empty,

    pub fn init(allocator: std.mem.Allocator) Sink {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Sink) void {
        for (self.records.items) |record| record.deinit(self.allocator);
        self.records.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn takeRecords(self: *Sink) ![]Record {
        try self.normalize(.{});
        return self.records.toOwnedSlice(self.allocator);
    }

    pub fn normalize(self: *Sink, options: NormalizeOptions) !void {
        std.mem.sort(Record, self.records.items, {}, lessThanRecord);
        suppressDuplicatesAndCascades(self);
        if (self.records.items.len <= options.max_diagnostics) return;

        const suppressed = self.records.items.len - options.max_diagnostics;
        const summary_path = self.records.items[options.max_diagnostics].path;
        const owned_summary_path = try self.allocator.dupe(u8, summary_path);
        errdefer self.allocator.free(owned_summary_path);
        const summary_message = try std.fmt.allocPrint(
            self.allocator,
            "{d} additional diagnostic{s} suppressed after the limit of {d}",
            .{ suppressed, if (suppressed == 1) "" else "s", options.max_diagnostics },
        );
        errdefer self.allocator.free(summary_message);
        const empty_labels = try self.allocator.alloc(Label, 0);
        errdefer self.allocator.free(empty_labels);
        const empty_notes = try self.allocator.alloc([]const u8, 0);
        errdefer self.allocator.free(empty_notes);
        const empty_fixes = try self.allocator.alloc(Fix, 0);
        errdefer self.allocator.free(empty_fixes);

        for (self.records.items[options.max_diagnostics..]) |record| {
            record.deinit(self.allocator);
        }
        self.records.shrinkRetainingCapacity(options.max_diagnostics);
        try self.records.append(self.allocator, .{
            .code = .diagnostic_limit_reached,
            .severity = .information,
            .path = owned_summary_path,
            .location = .path,
            .message = summary_message,
            .primary = null,
            .labels = empty_labels,
            .notes = empty_notes,
            .help = null,
            .fixes = empty_fixes,
        });
    }

    fn append(self: *Sink, spec: DiagnosticSpec) !void {
        const owned_path = try self.allocator.dupe(u8, spec.path);
        errdefer self.allocator.free(owned_path);
        const owned_message = try self.allocator.dupe(u8, spec.message);
        errdefer self.allocator.free(owned_message);

        const owned_labels = try self.allocator.alloc(Label, spec.labels.len);
        var labels_initialized: usize = 0;
        errdefer {
            for (owned_labels[0..labels_initialized]) |label| {
                self.allocator.free(label.span.path);
                self.allocator.free(label.message);
            }
            self.allocator.free(owned_labels);
        }
        for (spec.labels, owned_labels) |label, *owned| {
            const label_path = try self.allocator.dupe(u8, label.span.path);
            const label_message = self.allocator.dupe(u8, label.message) catch |err| {
                self.allocator.free(label_path);
                return err;
            };
            owned.* = .{
                .span = label.span,
                .message = label_message,
                .style = label.style,
            };
            owned.span.path = label_path;
            labels_initialized += 1;
        }

        const owned_notes = try self.allocator.alloc([]const u8, spec.notes.len);
        var notes_initialized: usize = 0;
        errdefer {
            for (owned_notes[0..notes_initialized]) |note| self.allocator.free(note);
            self.allocator.free(owned_notes);
        }
        for (spec.notes, owned_notes) |note, *owned| {
            owned.* = try self.allocator.dupe(u8, note);
            notes_initialized += 1;
        }

        const owned_help = if (spec.help) |help| try self.allocator.dupe(u8, help) else null;
        errdefer if (owned_help) |help| self.allocator.free(help);

        const owned_fixes = try self.allocator.alloc(Fix, spec.fixes.len);
        var fixes_initialized: usize = 0;
        errdefer {
            for (owned_fixes[0..fixes_initialized]) |fix| {
                self.allocator.free(fix.span.path);
                self.allocator.free(fix.replacement);
            }
            self.allocator.free(owned_fixes);
        }
        for (spec.fixes, owned_fixes) |fix, *owned| {
            const fix_path = try self.allocator.dupe(u8, fix.span.path);
            const replacement = self.allocator.dupe(u8, fix.replacement) catch |err| {
                self.allocator.free(fix_path);
                return err;
            };
            owned.* = .{
                .span = fix.span,
                .replacement = replacement,
                .applicability = fix.applicability,
            };
            owned.span.path = fix_path;
            fixes_initialized += 1;
        }

        var primary = spec.primary;
        if (primary) |*span| span.path = owned_path;
        const location: Location = if (spec.primary) |span|
            .{ .token = .{
                .tag = .eof,
                .lexeme = "",
                .offset = span.start,
                .end_offset = span.end,
                .line = span.line,
                .column = span.column,
                .end_column = span.end_column,
            } }
        else
            .path;

        try self.records.append(self.allocator, .{
            .code = spec.code,
            .severity = spec.severity,
            .path = owned_path,
            .location = location,
            .message = owned_message,
            .primary = primary,
            .labels = owned_labels,
            .notes = owned_notes,
            .help = owned_help,
            .fixes = owned_fixes,
        });
    }
};

fn severityPriority(severity: Severity) u8 {
    return switch (severity) {
        .err => 0,
        .warning => 1,
        .information => 2,
        .hint => 3,
    };
}

fn primaryStart(record: Record) usize {
    return if (record.primary) |span| span.start else 0;
}

fn primaryEnd(record: Record) usize {
    return if (record.primary) |span| span.end else 0;
}

fn codePriority(code: DiagnosticCode) usize {
    return if (code == .legacy_unclassified) std.math.maxInt(usize) else @backingInt(code);
}

fn lessThanRecord(_: void, left: Record, right: Record) bool {
    const path_order = std.mem.order(u8, left.path, right.path);
    if (path_order != .eq) return path_order == .lt;
    const left_start = primaryStart(left);
    const right_start = primaryStart(right);
    if (left_start != right_start) return left_start < right_start;
    const left_end = primaryEnd(left);
    const right_end = primaryEnd(right);
    if (left_end != right_end) return left_end < right_end;
    const left_severity = severityPriority(left.severity);
    const right_severity = severityPriority(right.severity);
    if (left_severity != right_severity) return left_severity < right_severity;
    const left_code = codePriority(left.code);
    const right_code = codePriority(right.code);
    if (left_code != right_code) return left_code < right_code;
    const message_order = std.mem.order(u8, left.message, right.message);
    if (message_order != .eq) return message_order == .lt;
    return compareRecordDetails(left, right) == .lt;
}

fn sameLocus(left: Record, right: Record) bool {
    return std.mem.eql(u8, left.path, right.path) and
        primaryStart(left) == primaryStart(right) and
        primaryEnd(left) == primaryEnd(right);
}

fn sameIdentity(left: Record, right: Record) bool {
    return sameLocus(left, right) and
        left.code == right.code and
        left.severity == right.severity and
        std.mem.eql(u8, left.message, right.message) and
        compareRecordDetails(left, right) == .eq;
}

fn orderUsize(left: usize, right: usize) std.math.Order {
    if (left < right) return .lt;
    if (left > right) return .gt;
    return .eq;
}

fn orderOptionalString(left: ?[]const u8, right: ?[]const u8) std.math.Order {
    if (left == null and right == null) return .eq;
    if (left == null) return .lt;
    if (right == null) return .gt;
    return std.mem.order(u8, left.?, right.?);
}

fn compareRecordDetails(left: Record, right: Record) std.math.Order {
    var order = orderUsize(left.labels.len, right.labels.len);
    if (order != .eq) return order;
    for (left.labels, right.labels) |left_label, right_label| {
        order = std.mem.order(u8, left_label.span.path, right_label.span.path);
        if (order != .eq) return order;
        order = orderUsize(left_label.span.start, right_label.span.start);
        if (order != .eq) return order;
        order = orderUsize(left_label.span.end, right_label.span.end);
        if (order != .eq) return order;
        order = std.mem.order(u8, left_label.message, right_label.message);
        if (order != .eq) return order;
        order = orderUsize(@backingInt(left_label.style), @backingInt(right_label.style));
        if (order != .eq) return order;
    }

    order = orderUsize(left.notes.len, right.notes.len);
    if (order != .eq) return order;
    for (left.notes, right.notes) |left_note, right_note| {
        order = std.mem.order(u8, left_note, right_note);
        if (order != .eq) return order;
    }
    order = orderOptionalString(left.help, right.help);
    if (order != .eq) return order;

    order = orderUsize(left.fixes.len, right.fixes.len);
    if (order != .eq) return order;
    for (left.fixes, right.fixes) |left_fix, right_fix| {
        order = std.mem.order(u8, left_fix.span.path, right_fix.span.path);
        if (order != .eq) return order;
        order = orderUsize(left_fix.span.start, right_fix.span.start);
        if (order != .eq) return order;
        order = orderUsize(left_fix.span.end, right_fix.span.end);
        if (order != .eq) return order;
        order = std.mem.order(u8, left_fix.replacement, right_fix.replacement);
        if (order != .eq) return order;
        order = orderUsize(@backingInt(left_fix.applicability), @backingInt(right_fix.applicability));
        if (order != .eq) return order;
    }
    return .eq;
}

fn suppressDuplicatesAndCascades(sink: *Sink) void {
    var read: usize = 0;
    var write: usize = 0;
    while (read < sink.records.items.len) {
        const group_start = read;
        var group_end = read + 1;
        var has_structured = sink.records.items[read].primary != null and
            sink.records.items[read].code != .legacy_unclassified;
        while (group_end < sink.records.items.len and sameLocus(
            sink.records.items[group_start],
            sink.records.items[group_end],
        )) : (group_end += 1) {
            has_structured = has_structured or
                (sink.records.items[group_end].primary != null and
                    sink.records.items[group_end].code != .legacy_unclassified);
        }

        var previous_kept: ?Record = null;
        for (sink.records.items[group_start..group_end]) |record| {
            const is_dependent_fallback = has_structured and record.code == .legacy_unclassified;
            const is_duplicate = if (previous_kept) |previous| sameIdentity(previous, record) else false;
            if (is_dependent_fallback or is_duplicate) {
                record.deinit(sink.allocator);
                continue;
            }
            sink.records.items[write] = record;
            previous_kept = record;
            write += 1;
        }
        read = group_end;
    }
    sink.records.shrinkRetainingCapacity(write);
}

pub const TextCapture = struct {
    allocator: std.mem.Allocator,
    buffer: *std.ArrayListUnmanaged(u8),
};

pub const Destination = union(enum) {
    discard,
    stderr,
    text: TextCapture,
    sink: *Sink,
};

pub const Context = struct {
    enabled: bool = true,
    destination: Destination = .stderr,
    default_code: DiagnosticCode = .legacy_unclassified,

    pub fn discarded() Context {
        return .{ .destination = .discard };
    }

    pub fn capturing(allocator: std.mem.Allocator, buffer: *std.ArrayListUnmanaged(u8)) Context {
        return .{ .destination = .{ .text = .{
            .allocator = allocator,
            .buffer = buffer,
        } } };
    }

    pub fn structured(sink: *Sink) Context {
        return .{ .destination = .{ .sink = sink } };
    }

    pub fn emit(self: *const Context, spec: DiagnosticSpec) !void {
        if (!self.enabled) return;
        switch (self.destination) {
            .discard => {},
            .stderr => renderCompactStderr(spec),
            .text => |capture| try renderCompactText(capture, spec),
            .sink => |sink| try sink.append(spec),
        }
    }

    pub fn emitPath(self: *const Context, path: []const u8, message: []const u8) !void {
        return self.emit(.{
            .code = self.default_code,
            .path = path,
            .message = message,
        });
    }

    pub fn emitToken(self: *const Context, path: []const u8, token: lexer.Token, comptime fmt: []const u8, args: anytype) !void {
        return self.emitTokenWith(path, token, .{ .code = self.default_code }, fmt, args);
    }

    pub fn emitTokenWith(
        self: *const Context,
        path: []const u8,
        token: lexer.Token,
        details: DiagnosticDetails,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        if (!self.enabled or self.destination == .discard) return;
        var buffer: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        writer.print(fmt, args) catch |err| switch (err) {
            error.WriteFailed => {
                const allocated = try std.fmt.allocPrint(std.heap.page_allocator, fmt, args);
                defer std.heap.page_allocator.free(allocated);
                return self.emit(.{
                    .code = details.code,
                    .severity = details.severity,
                    .path = path,
                    .message = allocated,
                    .primary = SourceSpan.fromToken(path, token),
                    .labels = details.labels,
                    .notes = details.notes,
                    .help = details.help,
                    .fixes = details.fixes,
                });
            },
        };
        return self.emit(.{
            .code = details.code,
            .severity = details.severity,
            .path = path,
            .message = writer.buffered(),
            .primary = SourceSpan.fromToken(path, token),
            .labels = details.labels,
            .notes = details.notes,
            .help = details.help,
            .fixes = details.fixes,
        });
    }
};

fn severityText(severity: Severity) []const u8 {
    return switch (severity) {
        .err => "error",
        .warning => "warning",
        .information => "information",
        .hint => "hint",
    };
}

pub fn renderCompactStderr(spec: DiagnosticSpec) void {
    if (spec.primary) |span| {
        std.debug.print("{s}:{d}:{d}:{d}: {s}: {s}\n", .{
            spec.path,
            span.line,
            span.column,
            span.end_column,
            severityText(spec.severity),
            spec.message,
        });
    } else {
        std.debug.print("{s}: {s}: {s}\n", .{
            spec.path,
            severityText(spec.severity),
            spec.message,
        });
    }
}

pub fn renderCompactText(capture: TextCapture, spec: DiagnosticSpec) !void {
    if (spec.primary) |span| {
        try capture.buffer.print(capture.allocator, "{s}:{d}:{d}:{d}: {s}: {s}\n", .{
            spec.path,
            span.line,
            span.column,
            span.end_column,
            severityText(spec.severity),
            spec.message,
        });
    } else {
        try capture.buffer.print(capture.allocator, "{s}: {s}: {s}\n", .{
            spec.path,
            severityText(spec.severity),
            spec.message,
        });
    }
}

test "structured sink records path and token diagnostics without text parsing" {
    var sink = Sink.init(std.testing.allocator);
    defer sink.deinit();
    const context = Context.structured(&sink);

    try context.emitPath("path.cy", "path failure");
    try context.emitToken("token.cy", .{
        .tag = .identifier,
        .lexeme = "name",
        .line = 3,
        .column = 5,
        .end_column = 9,
    }, "unknown `{s}`", .{"name"});

    try std.testing.expectEqual(@as(usize, 2), sink.records.items.len);
    try std.testing.expectEqual(DiagnosticCode.legacy_unclassified, sink.records.items[0].code);
    try std.testing.expectEqual(Severity.err, sink.records.items[0].severity);
    try std.testing.expectEqualStrings("path failure", sink.records.items[0].message);
    try std.testing.expect(sink.records.items[0].location == .path);
    try std.testing.expect(sink.records.items[0].primary == null);
    try std.testing.expectEqualStrings("unknown `name`", sink.records.items[1].message);
    try std.testing.expectEqual(@as(usize, 3), sink.records.items[1].location.token.line);
    try std.testing.expectEqual(@as(usize, 0), sink.records.items[1].primary.?.start);
    try std.testing.expectEqual(@as(usize, 0), sink.records.items[1].primary.?.end);
}

test "structured sink owns the complete diagnostic graph" {
    var sink = Sink.init(std.testing.allocator);
    defer sink.deinit();
    const context = Context.structured(&sink);

    var path = [_]u8{ 'm', 'a', 'i', 'n', '.', 'c', 'y' };
    var message = [_]u8{ 'b', 'o', 'r', 'r', 'o', 'w' };
    var label_path = [_]u8{ 'l', 'i', 'b', '.', 'c', 'y' };
    var label_message = [_]u8{ 'c', 'r', 'e', 'a', 't', 'e', 'd' };
    var note = [_]u8{ 's', 't', 'i', 'l', 'l', ' ', 'l', 'i', 'v', 'e' };
    var help = [_]u8{ 'c', 'o', 'p', 'y', ' ', 'i', 't' };
    var fix_path = [_]u8{ 'm', 'a', 'i', 'n', '.', 'c', 'y' };
    var replacement = [_]u8{ 'c', 'o', 'p', 'y' };
    const labels = [_]Label{.{
        .span = .{
            .path = &label_path,
            .start = 2,
            .end = 9,
            .line = 2,
            .column = 3,
            .end_column = 10,
        },
        .message = &label_message,
    }};
    const notes = [_][]const u8{&note};
    const fixes = [_]Fix{.{
        .span = .{
            .path = &fix_path,
            .start = 12,
            .end = 16,
            .line = 3,
            .column = 5,
            .end_column = 9,
        },
        .replacement = &replacement,
        .applicability = .maybe_incorrect,
    }};

    try context.emit(.{
        .code = .ownership,
        .severity = .warning,
        .path = &path,
        .message = &message,
        .primary = .{
            .path = &path,
            .start = 12,
            .end = 18,
            .line = 3,
            .column = 5,
            .end_column = 11,
        },
        .labels = &labels,
        .notes = &notes,
        .help = &help,
        .fixes = &fixes,
    });

    @memset(&path, 'x');
    @memset(&message, 'x');
    @memset(&label_path, 'x');
    @memset(&label_message, 'x');
    @memset(&note, 'x');
    @memset(&help, 'x');
    @memset(&fix_path, 'x');
    @memset(&replacement, 'x');

    const record = sink.records.items[0];
    try std.testing.expectEqual(DiagnosticCode.ownership, record.code);
    try std.testing.expectEqual(Severity.warning, record.severity);
    try std.testing.expectEqualStrings("main.cy", record.path);
    try std.testing.expectEqualStrings("borrow", record.message);
    try std.testing.expectEqualStrings("main.cy", record.primary.?.path);
    try std.testing.expectEqual(@as(usize, 12), record.primary.?.start);
    try std.testing.expectEqualStrings("lib.cy", record.labels[0].span.path);
    try std.testing.expectEqualStrings("created", record.labels[0].message);
    try std.testing.expectEqualStrings("still live", record.notes[0]);
    try std.testing.expectEqualStrings("copy it", record.help.?);
    try std.testing.expectEqualStrings("main.cy", record.fixes[0].span.path);
    try std.testing.expectEqualStrings("copy", record.fixes[0].replacement);
}

test "structured sink preserves emission order and request isolation" {
    var first_sink = Sink.init(std.testing.allocator);
    defer first_sink.deinit();
    var second_sink = Sink.init(std.testing.allocator);
    defer second_sink.deinit();

    const first = Context.structured(&first_sink);
    const second = Context.structured(&second_sink);
    try first.emitPath("first.cy", "first failure");
    try first.emitPath("first.cy", "second failure");
    try second.emitPath("second.cy", "isolated failure");

    try std.testing.expectEqual(@as(usize, 2), first_sink.records.items.len);
    try std.testing.expectEqualStrings("first failure", first_sink.records.items[0].message);
    try std.testing.expectEqualStrings("second failure", first_sink.records.items[1].message);
    try std.testing.expectEqual(@as(usize, 1), second_sink.records.items.len);
    try std.testing.expectEqualStrings("second.cy", second_sink.records.items[0].path);
    try std.testing.expectEqualStrings("isolated failure", second_sink.records.items[0].message);
}

test "explicit text context preserves legacy CLI rendering" {
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    const context = Context.capturing(std.testing.allocator, &buffer);

    try context.emitPath("path.cy", "path failure");
    try context.emitToken("token.cy", .{
        .tag = .identifier,
        .lexeme = "name",
        .line = 3,
        .column = 5,
        .end_column = 9,
    }, "unknown `{s}`", .{"name"});

    try std.testing.expectEqualStrings(
        "path.cy: error: path failure\n" ++
            "token.cy:3:5:9: error: unknown `name`\n",
        buffer.items,
    );
}

test "disabled explicit context does not emit" {
    var sink = Sink.init(std.testing.allocator);
    defer sink.deinit();
    var context = Context.structured(&sink);
    context.enabled = false;

    try context.emitPath("path.cy", "ignored");

    try std.testing.expectEqual(@as(usize, 0), sink.records.items.len);
}

fn emitRichDiagnosticForAllocationTest(allocator: std.mem.Allocator) !void {
    var sink = Sink.init(allocator);
    defer sink.deinit();
    const context = Context.structured(&sink);
    const labels = [_]Label{.{
        .span = .{ .path = "related.cy", .start = 1, .end = 2, .line = 1, .column = 2, .end_column = 3 },
        .message = "related declaration",
    }};
    const notes = [_][]const u8{"a note"};
    const fixes = [_]Fix{.{
        .span = .{ .path = "main.cy", .start = 3, .end = 4, .line = 1, .column = 4, .end_column = 5 },
        .replacement = "replacement",
    }};
    try context.emit(.{
        .code = .type_mismatch,
        .path = "main.cy",
        .message = "type mismatch",
        .primary = .{ .path = "main.cy", .start = 3, .end = 4, .line = 1, .column = 4, .end_column = 5 },
        .labels = &labels,
        .notes = &notes,
        .help = "change the expression",
        .fixes = &fixes,
    });
}

test "structured sink releases every partial allocation on failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        emitRichDiagnosticForAllocationTest,
        .{},
    );
}

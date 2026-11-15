const std = @import("std");
const compat = @import("../../compat.zig");
const diagnostics = @import("../diagnostics.zig");
const source_registry = @import("source_registry.zig");

pub const Mode = enum {
    compact,
    human,
};

pub const Options = struct {
    mode: Mode = .human,
    color: bool = false,
    tab_width: usize = 4,
};

pub fn hydrateFromDisk(registry: *source_registry.Registry, records: []const diagnostics.Record) void {
    for (records) |record| {
        hydratePath(registry, record.path);
        for (record.labels) |label| hydratePath(registry, label.span.path);
        for (record.fixes) |fix| hydratePath(registry, fix.span.path);
    }
}

fn hydratePath(registry: *source_registry.Registry, path: []const u8) void {
    if (registry.find(path) != null) return;
    const text = compat.readFileAlloc(registry.allocator, path, 16 * 1024 * 1024) catch return;
    defer registry.allocator.free(text);
    _ = registry.register(path, text) catch {};
}

pub fn renderAlloc(
    allocator: std.mem.Allocator,
    registry: *const source_registry.Registry,
    records: []const diagnostics.Record,
    options: Options,
) ![]u8 {
    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);
    try render(allocator, &output, registry, records, options);
    return output.toOwnedSlice(allocator);
}

pub fn render(
    allocator: std.mem.Allocator,
    output: *std.ArrayListUnmanaged(u8),
    registry: *const source_registry.Registry,
    records: []const diagnostics.Record,
    options: Options,
) !void {
    for (records, 0..) |record, index| {
        if (options.mode == .compact) {
            try diagnostics.renderCompactText(.{
                .allocator = allocator,
                .buffer = output,
            }, record.asSpec());
            continue;
        }
        if (index != 0) try output.append(allocator, '\n');
        try renderHumanRecord(allocator, output, registry, record, options);
    }
}

fn renderHumanRecord(
    allocator: std.mem.Allocator,
    output: *std.ArrayListUnmanaged(u8),
    registry: *const source_registry.Registry,
    record: diagnostics.Record,
    options: Options,
) !void {
    const severity = severityText(record.severity);
    const code_prefix = severityCodePrefix(record.severity);
    if (options.color) try output.print(allocator, "{s}", .{severityColor(record.severity)});
    try output.print(allocator, "{s}[{c}-{s}]", .{
        severity,
        code_prefix,
        @tagName(record.code),
    });
    if (options.color) try output.appendSlice(allocator, "\x1b[0m");
    try output.print(allocator, ": {s}\n", .{record.message});

    if (record.primary) |span| {
        try renderSpan(allocator, output, registry, span, " -->", '^', null, options.tab_width);
    } else {
        try output.print(allocator, " --> {s}\n", .{record.path});
    }

    for (record.labels) |label| {
        try renderSpan(
            allocator,
            output,
            registry,
            label.span,
            " :::",
            if (label.style == .primary) '^' else '-',
            label.message,
            options.tab_width,
        );
    }
    for (record.notes) |note| try output.print(allocator, "  = note: {s}\n", .{note});
    if (record.help) |help| try output.print(allocator, "  = help: {s}\n", .{help});
    for (record.fixes) |fix| {
        try output.print(allocator, "  = fix ({s}): replace {s}:{d}..{d} with `{s}`\n", .{
            applicabilityText(fix.applicability),
            fix.span.path,
            fix.span.start,
            fix.span.end,
            fix.replacement,
        });
    }
}

fn renderSpan(
    allocator: std.mem.Allocator,
    output: *std.ArrayListUnmanaged(u8),
    registry: *const source_registry.Registry,
    span: diagnostics.SourceSpan,
    location_prefix: []const u8,
    marker: u8,
    label: ?[]const u8,
    tab_width: usize,
) !void {
    const source_id = registry.find(span.path);
    const source = if (source_id) |id| registry.get(id) else null;
    const valid_offsets = source != null and span.start <= span.end and span.end <= source.?.text.len;
    if (!valid_offsets) {
        try output.print(allocator, "{s} {s}:{d}:{d}\n", .{
            location_prefix,
            span.path,
            span.line,
            span.column,
        });
        try output.appendSlice(allocator, "  = note: source unavailable; excerpt omitted\n");
        return;
    }

    const first_line = registry.lineAt(source_id.?, span.start).?;
    const first_column = visualWidth(
        source.?.text[first_line.start..span.start],
        tab_width,
        0,
    ) + 1;
    try output.print(allocator, "{s} {s}:{d}:{d}\n", .{
        location_prefix,
        span.path,
        first_line.number,
        first_column,
    });
    try renderExcerptLine(
        allocator,
        output,
        first_line,
        span.start,
        @min(@max(span.end, span.start +| 1), first_line.end),
        marker,
        if (span.end <= first_line.end) label else null,
        tab_width,
    );

    if (span.end > first_line.end) {
        const last_offset = if (span.end == 0) 0 else span.end - 1;
        const last_line = registry.lineAt(source_id.?, last_offset).?;
        if (last_line.number != first_line.number) {
            try appendRepeat(allocator, output, ' ', decimalDigits(first_line.number));
            try output.appendSlice(allocator, " | ...\n");
            try renderExcerptLine(
                allocator,
                output,
                last_line,
                last_line.start,
                @max(span.end, last_line.start +| 1),
                marker,
                label,
                tab_width,
            );
        }
    }
}

fn renderExcerptLine(
    allocator: std.mem.Allocator,
    output: *std.ArrayListUnmanaged(u8),
    line: source_registry.Line,
    span_start: usize,
    span_end: usize,
    marker: u8,
    label: ?[]const u8,
    tab_width: usize,
) !void {
    try output.print(allocator, "{d} | ", .{line.number});
    try appendExpanded(allocator, output, line.text, tab_width);
    try output.append(allocator, '\n');
    try appendRepeat(allocator, output, ' ', decimalDigits(line.number));
    try output.appendSlice(allocator, " | ");

    const bounded_start = @min(@max(span_start, line.start), line.end);
    const bounded_end = @min(@max(span_end, bounded_start +| 1), line.end);
    const prefix_width = visualWidth(line.text[0 .. bounded_start - line.start], tab_width, 0);
    const marker_width = @max(
        visualWidth(line.text[bounded_start - line.start .. bounded_end - line.start], tab_width, prefix_width),
        1,
    );
    try appendRepeat(allocator, output, ' ', prefix_width);
    if (marker == '^') {
        try output.append(allocator, '^');
        try appendRepeat(allocator, output, '~', marker_width - 1);
    } else {
        try appendRepeat(allocator, output, marker, marker_width);
    }
    if (label) |text| try output.print(allocator, " {s}", .{text});
    try output.append(allocator, '\n');
}

fn appendExpanded(
    allocator: std.mem.Allocator,
    output: *std.ArrayListUnmanaged(u8),
    text: []const u8,
    tab_width: usize,
) !void {
    var visual_column: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '\t') {
            const width = tabAdvance(visual_column, tab_width);
            try appendRepeat(allocator, output, ' ', width);
            visual_column += width;
            index += 1;
            continue;
        }
        const sequence_len = utf8SequenceLength(text, index);
        try output.appendSlice(allocator, text[index .. index + sequence_len]);
        visual_column += 1;
        index += sequence_len;
    }
}

fn visualWidth(text: []const u8, tab_width: usize, initial_column: usize) usize {
    var width: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '\t') {
            width += tabAdvance(initial_column + width, tab_width);
            index += 1;
        } else {
            index += utf8SequenceLength(text, index);
            width += 1;
        }
    }
    return width;
}

fn utf8SequenceLength(text: []const u8, index: usize) usize {
    const first = text[index];
    const expected: usize = if (first < 0x80)
        1
    else if (first & 0xe0 == 0xc0)
        2
    else if (first & 0xf0 == 0xe0)
        3
    else if (first & 0xf8 == 0xf0)
        4
    else
        1;
    if (index + expected > text.len) return 1;
    for (text[index + 1 .. index + expected]) |continuation| {
        if (continuation & 0xc0 != 0x80) return 1;
    }
    return expected;
}

fn tabAdvance(column: usize, configured_width: usize) usize {
    const width = @max(configured_width, 1);
    return width - (column % width);
}

fn appendRepeat(
    allocator: std.mem.Allocator,
    output: *std.ArrayListUnmanaged(u8),
    byte: u8,
    count: usize,
) !void {
    try output.ensureUnusedCapacity(allocator, count);
    for (0..count) |_| output.appendAssumeCapacity(byte);
}

fn decimalDigits(value: usize) usize {
    var remaining = value;
    var digits: usize = 1;
    while (remaining >= 10) : (digits += 1) remaining /= 10;
    return digits;
}

fn severityText(severity: diagnostics.Severity) []const u8 {
    return switch (severity) {
        .err => "error",
        .warning => "warning",
        .information => "information",
        .hint => "hint",
    };
}

fn severityCodePrefix(severity: diagnostics.Severity) u8 {
    return switch (severity) {
        .err => 'E',
        .warning => 'W',
        .information => 'I',
        .hint => 'H',
    };
}

fn severityColor(severity: diagnostics.Severity) []const u8 {
    return switch (severity) {
        .err => "\x1b[31;1m",
        .warning => "\x1b[33;1m",
        .information => "\x1b[36;1m",
        .hint => "\x1b[32;1m",
    };
}

fn applicabilityText(applicability: diagnostics.FixApplicability) []const u8 {
    return switch (applicability) {
        .machine_applicable => "machine-applicable",
        .maybe_incorrect => "maybe-incorrect",
        .has_placeholders => "has-placeholders",
        .unspecified => "unspecified",
    };
}

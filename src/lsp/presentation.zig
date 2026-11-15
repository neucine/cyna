const std = @import("std");
const diagnostic_sources = @import("../compiler/diagnostic/source_registry.zig");
const diagnostics = @import("../compiler/diagnostics.zig");
const analysis = @import("analysis.zig");

pub const Position = struct {
    line: usize,
    character: usize,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

pub const RelatedInformation = struct {
    path: []const u8,
    range: Range,
    message: []const u8,
};

pub const DocumentDiagnostic = struct {
    range: Range,
    severity: u8,
    code: diagnostics.DiagnosticCode,
    message: []const u8,
    related: []RelatedInformation,
    notes: []const []const u8,
    help: ?[]const u8,
    fixes: []const diagnostics.Fix,
};

pub const DocumentGroup = struct {
    path: []const u8,
    diagnostics: std.ArrayListUnmanaged(DocumentDiagnostic) = .empty,

    fn deinit(self: *DocumentGroup, allocator: std.mem.Allocator) void {
        for (self.diagnostics.items) |diagnostic| allocator.free(diagnostic.related);
        self.diagnostics.deinit(allocator);
    }
};

pub const WorkspaceDiagnostic = struct {
    path: []const u8,
    severity: u8,
    code: diagnostics.DiagnosticCode,
    message: []const u8,
};

pub const Publication = struct {
    allocator: std.mem.Allocator,
    documents: std.ArrayListUnmanaged(DocumentGroup) = .empty,
    workspace: std.ArrayListUnmanaged(WorkspaceDiagnostic) = .empty,

    pub fn deinit(self: *Publication) void {
        for (self.documents.items) |*group| group.deinit(self.allocator);
        self.documents.deinit(self.allocator);
        self.workspace.deinit(self.allocator);
        self.* = undefined;
    }
};

pub fn build(
    allocator: std.mem.Allocator,
    snapshot: *const analysis.Snapshot,
) !Publication {
    var publication = Publication{ .allocator = allocator };
    errdefer publication.deinit();

    for (snapshot.diagnostics) |record| {
        const primary = record.primary orelse {
            try appendWorkspace(&publication, record);
            continue;
        };
        const range = rangeForSpan(&snapshot.sources, primary) orelse {
            try appendWorkspace(&publication, record);
            continue;
        };
        const related = try buildRelated(allocator, &snapshot.sources, record.labels);
        const group = documentGroup(&publication, primary.path) catch |err| {
            allocator.free(related);
            return err;
        };
        group.diagnostics.append(allocator, .{
            .range = range,
            .severity = severityNumber(record.severity),
            .code = record.code,
            .message = record.message,
            .related = related,
            .notes = record.notes,
            .help = record.help,
            .fixes = record.fixes,
        }) catch |err| {
            allocator.free(related);
            return err;
        };
    }
    return publication;
}

fn appendWorkspace(publication: *Publication, record: diagnostics.Record) !void {
    try publication.workspace.append(publication.allocator, .{
        .path = record.path,
        .severity = severityNumber(record.severity),
        .code = record.code,
        .message = record.message,
    });
}

fn documentGroup(publication: *Publication, path: []const u8) !*DocumentGroup {
    for (publication.documents.items) |*group| {
        if (std.mem.eql(u8, group.path, path)) return group;
    }
    try publication.documents.append(publication.allocator, .{ .path = path });
    return &publication.documents.items[publication.documents.items.len - 1];
}

fn buildRelated(
    allocator: std.mem.Allocator,
    registry: *const diagnostic_sources.Registry,
    labels: []const diagnostics.Label,
) ![]RelatedInformation {
    var related: std.ArrayListUnmanaged(RelatedInformation) = .empty;
    errdefer related.deinit(allocator);
    for (labels) |label| {
        const range = rangeForSpan(registry, label.span) orelse continue;
        try related.append(allocator, .{
            .path = label.span.path,
            .range = range,
            .message = label.message,
        });
    }
    return related.toOwnedSlice(allocator);
}

pub fn rangeForSpan(
    registry: *const diagnostic_sources.Registry,
    span: diagnostics.SourceSpan,
) ?Range {
    const source = registry.sourceForPath(span.path) orelse return null;
    if (span.start > span.end or span.end > source.text.len) return null;
    return .{
        .start = positionAt(source.text, span.start) orelse return null,
        .end = positionAt(source.text, span.end) orelse return null,
    };
}

/// Converts a byte boundary into the zero-based UTF-16 position required by
/// LSP. Offsets inside a UTF-8 sequence and invalid UTF-8 return null.
pub fn positionAt(text: []const u8, offset: usize) ?Position {
    if (offset > text.len) return null;
    var line: usize = 0;
    var character: usize = 0;
    var index: usize = 0;
    while (index < offset) {
        const length: usize = std.unicode.utf8ByteSequenceLength(text[index]) catch return null;
        if (index + length > offset or index + length > text.len) return null;
        const codepoint = std.unicode.utf8Decode(text[index .. index + length]) catch return null;
        if (codepoint == '\n') {
            line += 1;
            character = 0;
        } else {
            character += if (codepoint > 0xffff) 2 else 1;
        }
        index += length;
    }
    return .{ .line = line, .character = character };
}

pub fn severityNumber(severity: diagnostics.Severity) u8 {
    return switch (severity) {
        .err => 1,
        .warning => 2,
        .information => 3,
        .hint => 4,
    };
}

pub fn pathToUriAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!std.fs.path.isAbsolute(path)) return error.RelativePath;
    var uri: std.ArrayListUnmanaged(u8) = .empty;
    errdefer uri.deinit(allocator);
    try uri.appendSlice(allocator, "file://");
    const hex = "0123456789ABCDEF";
    for (path) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '/' or byte == '-' or byte == '.' or byte == '_' or byte == '~' or byte == ':') {
            try uri.append(allocator, byte);
        } else {
            try uri.appendSlice(allocator, &.{ '%', hex[byte >> 4], hex[byte & 0x0f] });
        }
    }
    return uri.toOwnedSlice(allocator);
}

pub fn documentPayloadAlloc(
    allocator: std.mem.Allocator,
    uri: []const u8,
    items: []const DocumentDiagnostic,
) ![]u8 {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    errdefer payload.deinit(allocator);
    try payload.appendSlice(allocator, "{\"uri\":");
    try payload.print(allocator, "{f}", .{std.json.fmt(uri, .{})});
    try payload.appendSlice(allocator, ",\"diagnostics\":[");
    for (items, 0..) |item, index| {
        if (index != 0) try payload.append(allocator, ',');
        try appendDocumentDiagnosticJson(allocator, &payload, item);
    }
    try payload.appendSlice(allocator, "]}");
    return payload.toOwnedSlice(allocator);
}

fn appendDocumentDiagnosticJson(
    allocator: std.mem.Allocator,
    payload: *std.ArrayListUnmanaged(u8),
    item: DocumentDiagnostic,
) !void {
    try payload.print(
        allocator,
        "{{\"range\":{{\"start\":{{\"line\":{},\"character\":{}}},\"end\":{{\"line\":{},\"character\":{}}}}},\"severity\":{},\"code\":{f},\"source\":\"cyna\",\"message\":{f}",
        .{
            item.range.start.line,
            item.range.start.character,
            item.range.end.line,
            item.range.end.character,
            item.severity,
            std.json.fmt(@tagName(item.code), .{}),
            std.json.fmt(item.message, .{}),
        },
    );
    if (item.related.len != 0) {
        try payload.appendSlice(allocator, ",\"relatedInformation\":[");
        for (item.related, 0..) |related, index| {
            if (index != 0) try payload.append(allocator, ',');
            const related_uri = try pathToUriAlloc(allocator, related.path);
            defer allocator.free(related_uri);
            try payload.print(
                allocator,
                "{{\"location\":{{\"uri\":{f},\"range\":{{\"start\":{{\"line\":{},\"character\":{}}},\"end\":{{\"line\":{},\"character\":{}}}}}}},\"message\":{f}}}",
                .{
                    std.json.fmt(related_uri, .{}),
                    related.range.start.line,
                    related.range.start.character,
                    related.range.end.line,
                    related.range.end.character,
                    std.json.fmt(related.message, .{}),
                },
            );
        }
        try payload.append(allocator, ']');
    }
    if (item.notes.len != 0 or item.help != null or item.fixes.len != 0) {
        try payload.appendSlice(allocator, ",\"data\":{");
        var wrote_field = false;
        if (item.notes.len != 0) {
            try payload.appendSlice(allocator, "\"notes\":[");
            for (item.notes, 0..) |note, index| {
                if (index != 0) try payload.append(allocator, ',');
                try payload.print(allocator, "{f}", .{std.json.fmt(note, .{})});
            }
            try payload.append(allocator, ']');
            wrote_field = true;
        }
        if (item.help) |help| {
            if (wrote_field) try payload.append(allocator, ',');
            try payload.print(allocator, "\"help\":{f}", .{std.json.fmt(help, .{})});
            wrote_field = true;
        }
        if (item.fixes.len != 0) {
            if (wrote_field) try payload.append(allocator, ',');
            try payload.appendSlice(allocator, "\"fixes\":[");
            for (item.fixes, 0..) |fix, index| {
                if (index != 0) try payload.append(allocator, ',');
                try payload.print(
                    allocator,
                    "{{\"path\":{f},\"startByte\":{},\"endByte\":{},\"replacement\":{f},\"applicability\":{f}}}",
                    .{
                        std.json.fmt(fix.span.path, .{}),
                        fix.span.start,
                        fix.span.end,
                        std.json.fmt(fix.replacement, .{}),
                        std.json.fmt(@tagName(fix.applicability), .{}),
                    },
                );
            }
            try payload.append(allocator, ']');
        }
        try payload.append(allocator, '}');
    }
    try payload.append(allocator, '}');
}

pub fn workspacePayloadAlloc(
    allocator: std.mem.Allocator,
    item: WorkspaceDiagnostic,
) ![]u8 {
    const message = try std.fmt.allocPrint(
        allocator,
        "[{s}] {s}: {s}",
        .{ @tagName(item.code), item.path, item.message },
    );
    defer allocator.free(message);
    const message_type: u8 = switch (item.severity) {
        1 => 1,
        2 => 2,
        else => 3,
    };
    return std.fmt.allocPrint(
        allocator,
        "{{\"type\":{},\"message\":{f}}}",
        .{ message_type, std.json.fmt(message, .{}) },
    );
}

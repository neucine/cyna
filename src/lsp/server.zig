const std = @import("std");
const build_options = @import("build_options");
const compat = @import("../compat.zig");
const jsonrpc = @import("jsonrpc.zig");
const presentation = @import("presentation.zig");
const session_mod = @import("session.zig");
const symbols = @import("symbols.zig");

const max_message_bytes = 4 * 1024 * 1024;
const initialize_result = std.fmt.comptimePrint(
    "{{\"capabilities\":{{\"positionEncoding\":\"utf-16\",\"textDocumentSync\":{{\"openClose\":true,\"change\":1}},\"documentSymbolProvider\":true,\"definitionProvider\":true,\"hoverProvider\":true}},\"serverInfo\":{{\"name\":\"cyna\",\"version\":\"{s}\"}}}}",
    .{build_options.cyna_version},
);

const ErrorCode = struct {
    const invalid_request = -32600;
    const method_not_found = -32601;
};

pub fn run(allocator: std.mem.Allocator) !u8 {
    var stdin_buf: [4096]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(compat.io(), &stdin_buf);
    var stdout = std.Io.File.stdout().writerStreaming(compat.io(), &stdout_buf);
    const reader = &stdin.interface;
    const writer = &stdout.interface;

    var session = session_mod.Session.init(allocator);
    defer session.deinit();

    var shutdown_requested = false;

    while (true) {
        var request = jsonrpc.readRequest(allocator, reader, max_message_bytes) catch |err| {
            try jsonrpc.sendError(writer, null, ErrorCode.invalid_request, @errorName(err));
            continue;
        } orelse break;
        defer request.deinit();

        if (std.mem.eql(u8, request.method, "initialize")) {
            if (request.id) |id| try jsonrpc.sendResult(writer, id, initialize_result);
            continue;
        }

        if (std.mem.eql(u8, request.method, "initialized")) continue;

        if (std.mem.eql(u8, request.method, "textDocument/didOpen")) {
            try handleDidOpen(allocator, &session, writer, request.params orelse return error.InvalidRequest);
            continue;
        }

        if (std.mem.eql(u8, request.method, "textDocument/didChange")) {
            try handleDidChange(allocator, &session, writer, request.params orelse return error.InvalidRequest);
            continue;
        }

        if (std.mem.eql(u8, request.method, "textDocument/didClose")) {
            try handleDidClose(allocator, &session, writer, request.params orelse return error.InvalidRequest);
            continue;
        }

        if (std.mem.eql(u8, request.method, "textDocument/documentSymbol")) {
            const id = request.id orelse return error.InvalidRequest;
            const result = try handleDocumentSymbol(allocator, &session, request.params orelse return error.InvalidRequest);
            defer allocator.free(result);
            try jsonrpc.sendResult(writer, id, result);
            continue;
        }

        if (std.mem.eql(u8, request.method, "textDocument/hover")) {
            const id = request.id orelse return error.InvalidRequest;
            const result = try handleHover(allocator, &session, request.params orelse return error.InvalidRequest);
            defer allocator.free(result);
            try jsonrpc.sendResult(writer, id, result);
            continue;
        }

        if (std.mem.eql(u8, request.method, "textDocument/definition")) {
            const id = request.id orelse return error.InvalidRequest;
            const result = try handleDefinition(allocator, &session, request.params orelse return error.InvalidRequest);
            defer allocator.free(result);
            try jsonrpc.sendResult(writer, id, result);
            continue;
        }

        if (std.mem.eql(u8, request.method, "shutdown")) {
            shutdown_requested = true;
            if (request.id) |id| try jsonrpc.sendResult(writer, id, "null");
            continue;
        }

        if (std.mem.eql(u8, request.method, "exit")) {
            return if (shutdown_requested) 0 else 1;
        }

        if (request.id) |id| {
            try jsonrpc.sendError(writer, id, ErrorCode.method_not_found, "Method not found");
        }
    }

    return 0;
}

fn handleDidOpen(
    allocator: std.mem.Allocator,
    session: *session_mod.Session,
    writer: anytype,
    params: std.json.Value,
) !void {
    const text_document = try requireObjectField(params, "textDocument");
    const uri = try requireStringField(text_document, "uri");
    const text = try requireStringField(text_document, "text");
    const version = try requireIntField(text_document, "version");

    _ = try session.putDocument(uri, version, text);
    try publishDiagnostics(allocator, session, uri, writer);
}

fn handleDidChange(
    allocator: std.mem.Allocator,
    session: *session_mod.Session,
    writer: anytype,
    params: std.json.Value,
) !void {
    const text_document = try requireObjectField(params, "textDocument");
    const uri = try requireStringField(text_document, "uri");
    const version = try requireIntField(text_document, "version");
    const content_changes = try requireArrayField(params, "contentChanges");
    if (content_changes.items.len == 0) return;

    const last_change = content_changes.items[content_changes.items.len - 1];
    const change_object = switch (last_change) {
        .object => |object| object,
        else => return error.InvalidRequest,
    };
    const text = switch (change_object.get("text") orelse return error.InvalidRequest) {
        .string => |value| value,
        else => return error.InvalidRequest,
    };

    _ = try session.putDocument(uri, version, text);
    try publishDiagnostics(allocator, session, uri, writer);
}

fn handleDidClose(
    allocator: std.mem.Allocator,
    session: *session_mod.Session,
    writer: anytype,
    params: std.json.Value,
) !void {
    const text_document = try requireObjectField(params, "textDocument");
    const uri = try requireStringField(text_document, "uri");
    const requested_path = if (session.getDocument(uri)) |document| document.path else null;
    var requested_document_cleared = false;
    for (session.publishedDiagnosticPaths(uri)) |published_path| {
        const published_uri = try presentation.pathToUriAlloc(allocator, published_path);
        defer allocator.free(published_uri);
        try sendEmptyDiagnostics(allocator, writer, published_uri);
        if (requested_path) |path| {
            if (std.mem.eql(u8, published_path, path)) requested_document_cleared = true;
        }
    }
    session.clearPublishedDiagnosticPaths(uri);
    session.removeDocument(uri);
    if (!requested_document_cleared) try sendEmptyDiagnostics(allocator, writer, uri);
}

fn publishDiagnostics(
    allocator: std.mem.Allocator,
    session: *session_mod.Session,
    uri: []const u8,
    writer: anytype,
) !void {
    const document = session.getDocument(uri).?;
    const path = uriToPath(allocator, document.uri) catch return;
    defer allocator.free(path);

    const matches_disk = documentMatchesDisk(allocator, path, document.text) catch false;
    const snapshot = (try session.semanticDocument(uri, path, matches_disk)).?;
    var publication = try presentation.build(allocator, snapshot);
    defer publication.deinit();

    var requested_document_cleared = false;
    for (session.publishedDiagnosticPaths(uri)) |old_path| {
        if (publicationContainsPath(&publication, old_path)) continue;
        const old_uri = try presentation.pathToUriAlloc(allocator, old_path);
        defer allocator.free(old_uri);
        try sendEmptyDiagnostics(allocator, writer, old_uri);
        if (std.mem.eql(u8, old_path, path)) requested_document_cleared = true;
    }

    var published_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer published_paths.deinit(allocator);
    var requested_document_published = false;
    for (publication.documents.items) |group| {
        const group_uri = if (std.mem.eql(u8, group.path, path))
            try allocator.dupe(u8, document.uri)
        else
            try presentation.pathToUriAlloc(allocator, group.path);
        defer allocator.free(group_uri);
        try sendDocumentDiagnostics(allocator, writer, group_uri, group.diagnostics.items);
        try published_paths.append(allocator, group.path);
        if (std.mem.eql(u8, group.path, path)) requested_document_published = true;
    }
    if (!requested_document_published and !requested_document_cleared) {
        try sendEmptyDiagnostics(allocator, writer, document.uri);
    }
    try session.setPublishedDiagnosticPaths(uri, published_paths.items);

    for (publication.workspace.items) |item| {
        try sendWorkspaceDiagnostic(allocator, writer, item);
    }
}

fn publicationContainsPath(publication: *const presentation.Publication, path: []const u8) bool {
    for (publication.documents.items) |group| {
        if (std.mem.eql(u8, group.path, path)) return true;
    }
    return false;
}

fn sendEmptyDiagnostics(allocator: std.mem.Allocator, writer: anytype, uri: []const u8) !void {
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"uri\":{f},\"diagnostics\":[]}}",
        .{std.json.fmt(uri, .{})},
    );
    defer allocator.free(payload);
    try jsonrpc.sendNotification(writer, "textDocument/publishDiagnostics", payload);
}

fn sendDocumentDiagnostics(
    allocator: std.mem.Allocator,
    writer: anytype,
    uri: []const u8,
    items: []const presentation.DocumentDiagnostic,
) !void {
    const payload = try presentation.documentPayloadAlloc(allocator, uri, items);
    defer allocator.free(payload);
    try jsonrpc.sendNotification(writer, "textDocument/publishDiagnostics", payload);
}

fn sendWorkspaceDiagnostic(
    allocator: std.mem.Allocator,
    writer: anytype,
    item: presentation.WorkspaceDiagnostic,
) !void {
    const payload = try presentation.workspacePayloadAlloc(allocator, item);
    defer allocator.free(payload);
    try jsonrpc.sendNotification(writer, "window/showMessage", payload);
}

fn handleDocumentSymbol(
    allocator: std.mem.Allocator,
    session: *session_mod.Session,
    params: std.json.Value,
) ![]u8 {
    const text_document = try requireObjectField(params, "textDocument");
    const uri = try requireStringField(text_document, "uri");
    const path = try uriToPath(allocator, uri);
    defer allocator.free(path);

    if (session.getDocument(uri) != null) {
        const parsed = session.parsedDocument(uri, path) catch return try allocator.dupe(u8, "[]");
        return try symbols.documentSymbolsFromProgramJson(allocator, parsed.?.program);
    }

    const text = compat.readFileAlloc(allocator, path, max_message_bytes) catch return try allocator.dupe(u8, "[]");
    defer allocator.free(text);
    return try symbols.documentSymbolsJson(allocator, path, text);
}

fn handleHover(
    allocator: std.mem.Allocator,
    session: *session_mod.Session,
    params: std.json.Value,
) ![]u8 {
    const text_document = try requireObjectField(params, "textDocument");
    const uri = try requireStringField(text_document, "uri");
    const position = try requireObjectField(params, "position");
    const line = @as(usize, @intCast(try requireIntField(position, "line")));
    const character = @as(usize, @intCast(try requireIntField(position, "character")));
    const path = try uriToPath(allocator, uri);
    defer allocator.free(path);

    if (session.getDocument(uri)) |document| {
        const matches_disk = documentMatchesDisk(allocator, path, document.text) catch false;
        const semantic = (try session.semanticDocument(uri, path, matches_disk)).?;
        const parsed = session.parsedDocument(uri, path) catch null;
        return try symbols.hoverFromSemanticSnapshotJson(
            allocator,
            document.text,
            semantic,
            if (parsed) |value| value.program else null,
            line,
            character,
        );
    }

    const text = compat.readFileAlloc(allocator, path, max_message_bytes) catch return try allocator.dupe(u8, "null");
    defer allocator.free(text);
    return try symbols.hoverJsonLoaded(allocator, path, text, line, character);
}

fn handleDefinition(
    allocator: std.mem.Allocator,
    session: *session_mod.Session,
    params: std.json.Value,
) ![]u8 {
    const text_document = try requireObjectField(params, "textDocument");
    const uri = try requireStringField(text_document, "uri");
    const position = try requireObjectField(params, "position");
    const line = @as(usize, @intCast(try requireIntField(position, "line")));
    const character = @as(usize, @intCast(try requireIntField(position, "character")));
    const path = try uriToPath(allocator, uri);
    defer allocator.free(path);

    if (session.getDocument(uri)) |document| {
        const matches_disk = documentMatchesDisk(allocator, path, document.text) catch false;
        const semantic = (try session.semanticDocument(uri, path, matches_disk)).?;
        const parsed = session.parsedDocument(uri, path) catch null;
        return try symbols.definitionFromSemanticSnapshotJson(
            allocator,
            path,
            document.text,
            semantic,
            if (parsed) |value| value.program else null,
            line,
            character,
        );
    }

    const text = compat.readFileAlloc(allocator, path, max_message_bytes) catch return try allocator.dupe(u8, "null");
    defer allocator.free(text);
    return try symbols.definitionJsonLoaded(allocator, path, text, line, character);
}

fn documentMatchesDisk(allocator: std.mem.Allocator, path: []const u8, text: []const u8) !bool {
    const on_disk = compat.readFileAlloc(allocator, path, max_message_bytes) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(on_disk);
    return std.mem.eql(u8, on_disk, text);
}

fn uriToPath(allocator: std.mem.Allocator, uri_text: []const u8) ![]const u8 {
    const uri = try std.Uri.parse(uri_text);
    if (!std.mem.eql(u8, uri.scheme, "file")) return error.InvalidRequest;
    if (uri.host) |host| {
        var host_buffer: [256]u8 = undefined;
        const raw_host = try host.toRaw(&host_buffer);
        if (raw_host.len != 0 and !std.mem.eql(u8, raw_host, "localhost")) return error.InvalidRequest;
    }
    const raw_path = try uri.path.toRawMaybeAlloc(allocator);
    return try allocator.dupe(u8, raw_path);
}

fn requireObjectField(value: std.json.Value, name: []const u8) !std.json.ObjectMap {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidRequest,
    };
    return switch (object.get(name) orelse return error.InvalidRequest) {
        .object => |field| field,
        else => return error.InvalidRequest,
    };
}

fn requireArrayField(value: std.json.Value, name: []const u8) !std.json.Array {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidRequest,
    };
    return switch (object.get(name) orelse return error.InvalidRequest) {
        .array => |field| field,
        else => return error.InvalidRequest,
    };
}

fn requireStringField(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return switch (object.get(name) orelse return error.InvalidRequest) {
        .string => |field| field,
        else => return error.InvalidRequest,
    };
}

fn requireIntField(object: std.json.ObjectMap, name: []const u8) !i64 {
    return switch (object.get(name) orelse return error.InvalidRequest) {
        .integer => |field| field,
        else => return error.InvalidRequest,
    };
}

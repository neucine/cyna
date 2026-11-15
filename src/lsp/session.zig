const std = @import("std");
const analysis = @import("analysis.zig");
const compiler_diagnostics = @import("../compiler/diagnostics.zig");
const lexer = @import("../compiler/lexer/lexer.zig");
const ast = @import("../compiler/parser/ast.zig");
const parser = @import("../compiler/parser/parser.zig");

pub const ParsedDocument = struct {
    tokens: []lexer.Token,
    program: ast.Program,

    fn deinit(self: *ParsedDocument, allocator: std.mem.Allocator) void {
        self.program.deinit(allocator);
        allocator.free(self.tokens);
    }
};

const ParsedState = union(enum) {
    empty,
    ready: ParsedDocument,
    failed: anyerror,
};

const SemanticState = union(enum) {
    empty,
    ready: analysis.Snapshot,
};

pub const Document = struct {
    uri: []const u8,
    text: []const u8,
    path: ?[]const u8 = null,
    version: i64,
    revision: u64,
    parsed: ParsedState = .empty,
    semantic: SemanticState = .empty,
};

pub const PutResult = enum {
    opened,
    content_changed,
    version_changed,
    unchanged,
    stale,
};

pub const SemanticRequest = struct {
    uri: []const u8,
    path: []const u8,
    matches_disk: bool,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    documents: std.StringHashMapUnmanaged(Document) = .empty,
    next_revision: u64 = 1,
    parsed_cache_stats: ParsedCacheStats = .{},
    semantic_cache_stats: SemanticCacheStats = .{},
    dependency_graph: DependencyGraph = .{},
    scheduler_stats: SchedulerStats = .{},
    diagnostic_publications: std.StringHashMapUnmanaged([][]const u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Session {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Session) void {
        var iter = self.documents.iterator();
        while (iter.next()) |entry| {
            _ = deinitSemanticState(&entry.value_ptr.semantic, self.allocator);
            _ = deinitParsedState(&entry.value_ptr.parsed, self.allocator);
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.text);
            if (entry.value_ptr.path) |path| self.allocator.free(path);
        }
        self.documents.deinit(self.allocator);
        self.dependency_graph.deinit(self.allocator);
        var publication_iter = self.diagnostic_publications.iterator();
        while (publication_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            freeStringSlice(self.allocator, entry.value_ptr.*);
        }
        self.diagnostic_publications.deinit(self.allocator);
    }

    /// Installs a document revision without invalidating content-derived work
    /// for metadata-only version changes. Stale LSP changes are ignored.
    pub fn putDocument(self: *Session, uri: []const u8, version: i64, text: []const u8) !PutResult {
        if (self.documents.getPtr(uri)) |document| {
            if (version < document.version) return .stale;
            if (std.mem.eql(u8, document.text, text)) {
                if (version == document.version) return .unchanged;
                document.version = version;
                return .version_changed;
            }

            const owned_text = try self.allocator.dupe(u8, text);
            if (document.path) |path| try self.invalidateDependents(path, uri);
            if (deinitSemanticState(&document.semantic, self.allocator)) {
                self.semantic_cache_stats.invalidations += 1;
            }
            self.dependency_graph.removeDependent(self.allocator, uri);
            if (deinitParsedState(&document.parsed, self.allocator)) {
                self.parsed_cache_stats.invalidations += 1;
            }
            self.allocator.free(document.text);
            document.text = owned_text;
            document.version = version;
            document.revision = self.takeRevision();
            return .content_changed;
        }

        const owned_uri = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(owned_uri);
        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);

        const result = try self.documents.getOrPut(self.allocator, owned_uri);
        std.debug.assert(!result.found_existing);
        result.key_ptr.* = owned_uri;
        result.value_ptr.* = .{
            .uri = result.key_ptr.*,
            .text = owned_text,
            .version = version,
            .revision = self.takeRevision(),
        };
        return .opened;
    }

    pub fn getDocument(self: *Session, uri: []const u8) ?*Document {
        return self.documents.getPtr(uri);
    }

    pub fn parsedDocument(self: *Session, uri: []const u8, path: []const u8) !?*const ParsedDocument {
        try self.bindDocumentPath(uri, path);
        const document = self.documents.getPtr(uri) orelse return null;
        switch (document.parsed) {
            .ready => {
                self.parsed_cache_stats.hits += 1;
                return &document.parsed.ready;
            },
            .failed => |err| {
                self.parsed_cache_stats.hits += 1;
                return err;
            },
            .empty => {},
        }

        self.parsed_cache_stats.misses += 1;
        const tokens = try lexer.lexAll(self.allocator, document.text);
        var diagnostic_context = compiler_diagnostics.Context.discarded();
        const program = parser.parseWithDiagnostics(self.allocator, path, document.text, tokens, &diagnostic_context) catch |err| {
            self.allocator.free(tokens);
            if (err == error.ParseFailed) {
                document.parsed = .{ .failed = err };
            }
            return err;
        };
        document.parsed = .{ .ready = .{
            .tokens = tokens,
            .program = program,
        } };
        return &document.parsed.ready;
    }

    pub fn parsedCacheSnapshot(self: *const Session) ParsedCacheSnapshot {
        return .{
            .hits = self.parsed_cache_stats.hits,
            .misses = self.parsed_cache_stats.misses,
            .invalidations = self.parsed_cache_stats.invalidations,
        };
    }

    pub fn semanticDocument(
        self: *Session,
        uri: []const u8,
        path: []const u8,
        matches_disk: bool,
    ) !?*const analysis.Snapshot {
        try self.bindDocumentPath(uri, path);
        const document = self.documents.getPtr(uri) orelse return null;
        switch (document.semantic) {
            .ready => |snapshot| {
                if (snapshot.matches_disk == matches_disk) {
                    self.semantic_cache_stats.hits += 1;
                    return &document.semantic.ready;
                }
                _ = deinitSemanticState(&document.semantic, self.allocator);
                self.semantic_cache_stats.invalidations += 1;
                self.dependency_graph.removeDependent(self.allocator, uri);
            },
            .empty => {},
        }

        self.semantic_cache_stats.misses += 1;
        var snapshot = try analysis.buildWithOptions(self.allocator, path, document.text, .{
            .matches_disk = matches_disk,
            .source_overlay = .{
                .context = self,
                .getFn = openDocumentSource,
            },
        });
        errdefer snapshot.deinit(self.allocator);
        try self.dependency_graph.register(self.allocator, uri, snapshot.dependencies);
        document.semantic = .{ .ready = snapshot };
        return &document.semantic.ready;
    }

    pub fn semanticCacheSnapshot(self: *const Session) SemanticCacheSnapshot {
        return .{
            .hits = self.semantic_cache_stats.hits,
            .misses = self.semantic_cache_stats.misses,
            .invalidations = self.semantic_cache_stats.invalidations,
            .dependency_invalidations = self.semantic_cache_stats.dependency_invalidations,
        };
    }

    pub fn dependencyGraphSnapshot(self: *const Session) DependencyGraphSnapshot {
        return self.dependency_graph.snapshot();
    }

    pub fn prepareSemanticDocuments(
        self: *Session,
        result_allocator: std.mem.Allocator,
        requests: []const SemanticRequest,
        max_parallelism: usize,
    ) ![]*const analysis.Snapshot {
        const results = try result_allocator.alloc(*const analysis.Snapshot, requests.len);
        errdefer result_allocator.free(results);
        if (requests.len == 0) return results;

        for (requests) |request| {
            try self.bindDocumentPath(request.uri, request.path);
            if (self.documents.get(request.uri) == null) return error.DocumentNotOpen;
        }

        var jobs: std.ArrayListUnmanaged(SemanticBuildJob) = .empty;
        defer jobs.deinit(result_allocator);
        for (requests) |request| {
            const document = self.documents.getPtr(request.uri).?;
            switch (document.semantic) {
                .ready => |snapshot| {
                    if (snapshot.matches_disk == request.matches_disk) {
                        self.semantic_cache_stats.hits += 1;
                        continue;
                    }
                    _ = deinitSemanticState(&document.semantic, self.allocator);
                    self.semantic_cache_stats.invalidations += 1;
                    self.dependency_graph.removeDependent(self.allocator, request.uri);
                },
                .empty => {},
            }

            var duplicate = false;
            for (jobs.items) |job| {
                if (job.revision == document.revision and
                    job.matches_disk == request.matches_disk and
                    std.mem.eql(u8, job.uri, request.uri))
                {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) {
                self.semantic_cache_stats.hits += 1;
                self.scheduler_stats.coalesced_requests += 1;
                continue;
            }

            try jobs.append(result_allocator, .{
                .uri = request.uri,
                .path = request.path,
                .text = document.text,
                .revision = document.revision,
                .matches_disk = request.matches_disk,
            });
        }

        if (jobs.items.len != 0) {
            self.semantic_cache_stats.misses += @intCast(jobs.items.len);
            const requested_parallelism = if (max_parallelism == 0) 1 else max_parallelism;
            const worker_count = @min(requested_parallelism, jobs.items.len);
            self.scheduler_stats.batches += 1;
            self.scheduler_stats.jobs += @intCast(jobs.items.len);
            self.scheduler_stats.max_scheduled_parallelism = @max(
                self.scheduler_stats.max_scheduled_parallelism,
                worker_count,
            );

            var worker_context = SemanticWorkerContext{
                .session = self,
                .jobs = jobs.items,
            };
            if (worker_count == 1) {
                semanticWorker(&worker_context);
            } else {
                const threads = try result_allocator.alloc(std.Thread, worker_count);
                defer result_allocator.free(threads);
                var spawned: usize = 0;
                errdefer {
                    worker_context.stop.store(true, .release);
                    for (threads[0..spawned]) |thread| thread.join();
                }
                while (spawned < worker_count) : (spawned += 1) {
                    threads[spawned] = try std.Thread.spawn(.{}, semanticWorker, .{&worker_context});
                }
                for (threads) |thread| thread.join();
            }

            for (jobs.items) |job| {
                if (job.failure) |err| {
                    deinitUnclaimedJobSnapshots(self.allocator, jobs.items);
                    return err;
                }
            }

            for (jobs.items) |*job| {
                var snapshot = job.snapshot orelse return error.SemanticBuildMissingResult;
                job.snapshot = null;
                self.dependency_graph.register(self.allocator, job.uri, snapshot.dependencies) catch |err| {
                    snapshot.deinit(self.allocator);
                    deinitUnclaimedJobSnapshots(self.allocator, jobs.items);
                    return err;
                };
                const document = self.documents.getPtr(job.uri).?;
                std.debug.assert(document.revision == job.revision);
                document.semantic = .{ .ready = snapshot };
            }
        }

        for (requests, results) |request, *result| {
            const document = self.documents.getPtr(request.uri).?;
            result.* = switch (document.semantic) {
                .ready => &document.semantic.ready,
                .empty => return error.SemanticBuildMissingResult,
            };
        }
        return results;
    }

    pub fn schedulerSnapshot(self: *const Session) SchedulerSnapshot {
        return .{
            .batches = self.scheduler_stats.batches,
            .jobs = self.scheduler_stats.jobs,
            .coalesced_requests = self.scheduler_stats.coalesced_requests,
            .max_scheduled_parallelism = self.scheduler_stats.max_scheduled_parallelism,
        };
    }

    pub fn publishedDiagnosticPaths(self: *const Session, uri: []const u8) []const []const u8 {
        return self.diagnostic_publications.get(uri) orelse &.{};
    }

    pub fn setPublishedDiagnosticPaths(
        self: *Session,
        uri: []const u8,
        paths: []const []const u8,
    ) !void {
        const owned_paths = try self.allocator.alloc([]const u8, paths.len);
        var initialized: usize = 0;
        errdefer {
            for (owned_paths[0..initialized]) |path| self.allocator.free(path);
            self.allocator.free(owned_paths);
        }
        for (paths, owned_paths) |path, *owned| {
            owned.* = try self.allocator.dupe(u8, path);
            initialized += 1;
        }

        if (self.diagnostic_publications.getPtr(uri)) |existing| {
            freeStringSlice(self.allocator, existing.*);
            existing.* = owned_paths;
            return;
        }
        const owned_uri = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(owned_uri);
        try self.diagnostic_publications.put(self.allocator, owned_uri, owned_paths);
    }

    pub fn clearPublishedDiagnosticPaths(self: *Session, uri: []const u8) void {
        const removed = self.diagnostic_publications.fetchRemove(uri) orelse return;
        self.allocator.free(removed.key);
        freeStringSlice(self.allocator, removed.value);
    }

    pub fn removeDocument(self: *Session, uri: []const u8) void {
        if (self.documents.get(uri)) |document| {
            if (document.path) |path| {
                self.invalidateDependents(path, uri) catch self.invalidateAllSemanticExcept(uri);
            }
        }
        const removed = self.documents.fetchRemove(uri) orelse return;
        var document = removed.value;
        self.dependency_graph.removeDependent(self.allocator, uri);
        _ = deinitSemanticState(&document.semantic, self.allocator);
        _ = deinitParsedState(&document.parsed, self.allocator);
        self.allocator.free(removed.value.text);
        if (document.path) |path| self.allocator.free(path);
        self.allocator.free(removed.key);
    }

    fn bindDocumentPath(self: *Session, uri: []const u8, path: []const u8) !void {
        const document = self.documents.getPtr(uri) orelse return;
        if (document.path) |existing| {
            if (std.mem.eql(u8, existing, path)) return;
            try self.invalidateDependents(existing, uri);
            try self.invalidateDependents(path, uri);
            self.dependency_graph.removeDependent(self.allocator, uri);
            if (deinitSemanticState(&document.semantic, self.allocator)) {
                self.semantic_cache_stats.invalidations += 1;
            }
            if (deinitParsedState(&document.parsed, self.allocator)) {
                self.parsed_cache_stats.invalidations += 1;
            }
            self.allocator.free(existing);
            document.path = try self.allocator.dupe(u8, path);
            return;
        }

        try self.invalidateDependents(path, uri);
        document.path = try self.allocator.dupe(u8, path);
    }

    fn invalidateDependents(self: *Session, changed_path: []const u8, excluded_uri: []const u8) !void {
        var queue: std.ArrayListUnmanaged([]const u8) = .empty;
        defer queue.deinit(self.allocator);
        try queue.append(self.allocator, changed_path);

        var index: usize = 0;
        while (index < queue.items.len) : (index += 1) {
            const path = queue.items[index];
            var already_visited = false;
            for (queue.items[0..index]) |visited| {
                if (std.mem.eql(u8, visited, path)) {
                    already_visited = true;
                    break;
                }
            }
            if (already_visited) continue;

            for (self.dependency_graph.dependents(path)) |dependent_uri| {
                if (std.mem.eql(u8, dependent_uri, excluded_uri)) continue;
                const dependent = self.documents.getPtr(dependent_uri) orelse continue;
                if (deinitSemanticState(&dependent.semantic, self.allocator)) {
                    self.semantic_cache_stats.invalidations += 1;
                    self.semantic_cache_stats.dependency_invalidations += 1;
                }
                if (dependent.path) |dependent_path| {
                    try queue.append(self.allocator, dependent_path);
                }
            }
        }
    }

    fn invalidateAllSemanticExcept(self: *Session, excluded_uri: []const u8) void {
        var iterator = self.documents.iterator();
        while (iterator.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, excluded_uri)) continue;
            if (deinitSemanticState(&entry.value_ptr.semantic, self.allocator)) {
                self.semantic_cache_stats.invalidations += 1;
                self.semantic_cache_stats.dependency_invalidations += 1;
            }
        }
    }

    fn takeRevision(self: *Session) u64 {
        const revision = self.next_revision;
        self.next_revision +%= 1;
        if (self.next_revision == 0) self.next_revision = 1;
        return revision;
    }

    fn openDocumentSource(context: *anyopaque, canonical_path: []const u8) ?[]const u8 {
        const self: *Session = @ptrCast(@alignCast(context));
        var iterator = self.documents.iterator();
        while (iterator.next()) |entry| {
            const path = entry.value_ptr.path orelse continue;
            if (std.mem.eql(u8, path, canonical_path)) return entry.value_ptr.text;
        }
        return null;
    }
};

fn freeStringSlice(allocator: std.mem.Allocator, values: [][]const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

const SemanticBuildJob = struct {
    uri: []const u8,
    path: []const u8,
    text: []const u8,
    revision: u64,
    matches_disk: bool,
    snapshot: ?analysis.Snapshot = null,
    failure: ?anyerror = null,
};

const SemanticWorkerContext = struct {
    session: *Session,
    jobs: []SemanticBuildJob,
    next_job: std.atomic.Value(usize) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),
};

fn semanticWorker(context: *SemanticWorkerContext) void {
    while (!context.stop.load(.acquire)) {
        const index = context.next_job.fetchAdd(1, .monotonic);
        if (index >= context.jobs.len) return;
        const job = &context.jobs[index];
        job.snapshot = analysis.buildWithOptions(context.session.allocator, job.path, job.text, .{
            .matches_disk = job.matches_disk,
            .source_overlay = .{
                .context = context.session,
                .getFn = Session.openDocumentSource,
            },
        }) catch |err| {
            job.failure = err;
            return;
        };
    }
}

fn deinitUnclaimedJobSnapshots(allocator: std.mem.Allocator, jobs: []SemanticBuildJob) void {
    for (jobs) |*job| {
        if (job.snapshot) |*snapshot| snapshot.deinit(allocator);
        job.snapshot = null;
    }
}

const ParsedCacheStats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    invalidations: u64 = 0,
};

const SchedulerStats = struct {
    batches: u64 = 0,
    jobs: u64 = 0,
    coalesced_requests: u64 = 0,
    max_scheduled_parallelism: usize = 0,
};

pub const SchedulerSnapshot = struct {
    batches: u64,
    jobs: u64,
    coalesced_requests: u64,
    max_scheduled_parallelism: usize,
};

const SemanticCacheStats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    invalidations: u64 = 0,
    dependency_invalidations: u64 = 0,
};

pub const SemanticCacheSnapshot = struct {
    hits: u64,
    misses: u64,
    invalidations: u64,
    dependency_invalidations: u64,
};

pub const ParsedCacheSnapshot = struct {
    hits: u64,
    misses: u64,
    invalidations: u64,
};

fn deinitParsedState(state: *ParsedState, allocator: std.mem.Allocator) bool {
    const occupied = switch (state.*) {
        .empty => false,
        .ready => |*parsed| blk: {
            parsed.deinit(allocator);
            break :blk true;
        },
        .failed => true,
    };
    state.* = .empty;
    return occupied;
}

fn deinitSemanticState(state: *SemanticState, allocator: std.mem.Allocator) bool {
    const occupied = switch (state.*) {
        .empty => false,
        .ready => |*snapshot| blk: {
            snapshot.deinit(allocator);
            break :blk true;
        },
    };
    state.* = .empty;
    return occupied;
}

const DependencyGraph = struct {
    const UriList = std.ArrayListUnmanaged([]const u8);

    reverse: std.StringHashMapUnmanaged(UriList) = .empty,

    fn deinit(self: *DependencyGraph, allocator: std.mem.Allocator) void {
        var iterator = self.reverse.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |uri| allocator.free(uri);
            entry.value_ptr.deinit(allocator);
        }
        self.reverse.deinit(allocator);
    }

    fn register(
        self: *DependencyGraph,
        allocator: std.mem.Allocator,
        uri: []const u8,
        dependencies: []const []const u8,
    ) !void {
        self.removeDependent(allocator, uri);
        errdefer self.removeDependent(allocator, uri);

        for (dependencies) |path| {
            const owned_path = try allocator.dupe(u8, path);
            const entry = self.reverse.getOrPut(allocator, owned_path) catch |err| {
                allocator.free(owned_path);
                return err;
            };
            if (entry.found_existing) {
                allocator.free(owned_path);
            } else {
                entry.value_ptr.* = .empty;
            }
            for (entry.value_ptr.items) |existing_uri| {
                if (std.mem.eql(u8, existing_uri, uri)) break;
            } else {
                const owned_uri = try allocator.dupe(u8, uri);
                entry.value_ptr.append(allocator, owned_uri) catch |err| {
                    allocator.free(owned_uri);
                    return err;
                };
            }
        }
    }

    fn removeDependent(self: *DependencyGraph, allocator: std.mem.Allocator, uri: []const u8) void {
        var empty_keys: std.ArrayListUnmanaged([]const u8) = .empty;
        defer empty_keys.deinit(allocator);
        var iterator = self.reverse.iterator();
        while (iterator.next()) |entry| {
            var index: usize = 0;
            while (index < entry.value_ptr.items.len) {
                if (!std.mem.eql(u8, entry.value_ptr.items[index], uri)) {
                    index += 1;
                    continue;
                }
                allocator.free(entry.value_ptr.items[index]);
                _ = entry.value_ptr.swapRemove(index);
            }
            if (entry.value_ptr.items.len == 0) {
                empty_keys.append(allocator, entry.key_ptr.*) catch {};
            }
        }
        for (empty_keys.items) |key| {
            var removed = self.reverse.fetchRemove(key) orelse continue;
            allocator.free(removed.key);
            removed.value.deinit(allocator);
        }
    }

    fn dependents(self: *const DependencyGraph, path: []const u8) []const []const u8 {
        const list = self.reverse.get(path) orelse return &.{};
        return list.items;
    }

    fn snapshot(self: *const DependencyGraph) DependencyGraphSnapshot {
        var nodes: u64 = 0;
        var edges: u64 = 0;
        var iterator = self.reverse.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.items.len == 0) continue;
            nodes += 1;
            edges += entry.value_ptr.items.len;
        }
        return .{ .nodes = nodes, .edges = edges };
    }
};

pub const DependencyGraphSnapshot = struct {
    nodes: u64,
    edges: u64,
};

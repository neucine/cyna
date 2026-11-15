const std = @import("std");
const telemetry = @import("zig_libs").telemetry;
const compat = @import("../compat.zig");
const lexer = @import("lexer/lexer.zig");

const trace = telemetry.trace;

pub const CompilationSession = struct {
    allocator: std.mem.Allocator,
    enabled: bool,
    storage: []trace.RecordSlot,
    buffer: *trace.Buffer,
    tracer: trace.Tracer,
    cache_mutex: Mutex = .{},
    cache: std.StringHashMapUnmanaged(*CacheEntry) = .empty,
    cache_stats: CacheStats = .{},
    module_cache_hits: usize = 0,
    module_cache_misses: usize = 0,
    module_workers: usize = 0,
    native_objects_reused: usize = 0,
    native_objects_compiled: usize = 0,
    slow_functions: [10]SlowFunction = undefined,
    slow_function_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, enabled: bool) !CompilationSession {
        const storage = if (enabled)
            try allocator.alloc(trace.RecordSlot, 16 * 1024)
        else
            try allocator.alloc(trace.RecordSlot, 0);
        errdefer allocator.free(storage);
        const buffer = try allocator.create(trace.Buffer);
        errdefer allocator.destroy(buffer);
        buffer.* = trace.Buffer.init(storage);
        var session = CompilationSession{
            .allocator = allocator,
            .enabled = enabled,
            .storage = storage,
            .buffer = buffer,
            .tracer = undefined,
        };
        session.tracer = trace.Tracer.init(buffer, 0xc71a);
        return session;
    }

    pub fn deinit(self: *CompilationSession) void {
        for (self.slow_functions[0..self.slow_function_count]) |entry| self.allocator.free(entry.name);
        var cache_iterator = self.cache.iterator();
        while (cache_iterator.next()) |item| {
            const entry = item.value_ptr.*;
            self.allocator.free(entry.path);
            if (entry.source) |source| self.allocator.free(source);
            if (entry.tokens) |tokens| self.allocator.free(tokens);
            self.allocator.destroy(entry);
        }
        self.cache.deinit(self.allocator);
        self.allocator.free(self.storage);
        self.allocator.destroy(self.buffer);
    }

    /// Returns an owned source buffer. The session keeps one immutable copy so
    /// concurrent compilation roots read a path only once per invocation.
    pub fn loadSource(self: *CompilationSession, path: []const u8, max_bytes: usize) ![]u8 {
        const entry, const producer = try self.cacheEntry(path);
        if (producer) {
            _ = self.cache_stats.source_misses.fetchAdd(1, .monotonic);
            const source = compat.readFileAlloc(self.allocator, path, max_bytes) catch |err| {
                entry.source_error = err;
                entry.source_state.store(.failed, .release);
                return err;
            };
            entry.source = source;
            entry.source_state.store(.ready, .release);
        } else {
            const current_state = entry.source_state.load(.acquire);
            if (current_state == .loading) {
                _ = self.cache_stats.source_waits.fetchAdd(1, .monotonic);
            } else {
                _ = self.cache_stats.source_hits.fetchAdd(1, .monotonic);
            }
            try waitForState(&entry.source_state, &entry.source_error);
        }
        return self.allocator.dupe(u8, entry.source.?);
    }

    /// Lexes through an offset-based immutable cache. Returned tokens reference
    /// the caller's source buffer, preserving the loader's existing ownership.
    pub fn lexSource(self: *CompilationSession, path: []const u8, source: []const u8) ![]lexer.Token {
        const entry, _ = try self.cacheEntry(path);
        try waitForState(&entry.source_state, &entry.source_error);

        if (entry.token_state.cmpxchgStrong(.empty, .loading, .acq_rel, .acquire) == null) {
            _ = self.cache_stats.token_misses.fetchAdd(1, .monotonic);
            const cached_tokens = lexer.lexAll(self.allocator, entry.source.?) catch |err| {
                entry.token_error = err;
                entry.token_state.store(.failed, .release);
                return err;
            };
            defer self.allocator.free(cached_tokens);
            const templates = self.allocator.alloc(TokenTemplate, cached_tokens.len) catch |err| {
                entry.token_error = err;
                entry.token_state.store(.failed, .release);
                return err;
            };
            for (templates, cached_tokens) |*template, token| {
                const lexeme_start = @intFromPtr(token.lexeme.ptr) - @intFromPtr(entry.source.?.ptr);
                template.* = .{
                    .tag = token.tag,
                    .start = lexeme_start,
                    .len = token.lexeme.len,
                    .line = token.line,
                    .column = token.column,
                    .end_column = token.end_column,
                };
            }
            entry.tokens = templates;
            entry.token_state.store(.ready, .release);
        } else {
            const current_state = entry.token_state.load(.acquire);
            if (current_state == .loading) {
                _ = self.cache_stats.token_waits.fetchAdd(1, .monotonic);
            } else {
                _ = self.cache_stats.token_hits.fetchAdd(1, .monotonic);
            }
            try waitForState(&entry.token_state, &entry.token_error);
        }

        const output = try self.allocator.alloc(lexer.Token, entry.tokens.?.len);
        for (output, entry.tokens.?) |*token, template| {
            token.* = .{
                .tag = template.tag,
                .lexeme = source[template.start .. template.start + template.len],
                // The template's start is the token's byte offset in the source,
                // so the cached lexeme reproduces the offsets a direct lex would.
                .offset = template.start,
                .end_offset = template.start + template.len,
                .line = template.line,
                .column = template.column,
                .end_column = template.end_column,
            };
        }
        return output;
    }

    fn cacheEntry(self: *CompilationSession, path: []const u8) !struct { *CacheEntry, bool } {
        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();
        if (self.cache.get(path)) |entry| return .{ entry, false };

        const entry = try self.allocator.create(CacheEntry);
        errdefer self.allocator.destroy(entry);
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        entry.* = .{ .path = owned_path };
        entry.source_state.store(.loading, .release);
        try self.cache.put(self.allocator, owned_path, entry);
        return .{ entry, true };
    }

    pub fn start(self: *CompilationSession, name: []const u8, attributes: []const telemetry.Attribute) Scope {
        if (!self.enabled) return .{};
        const started_ns = now();
        const span = self.tracer.startSpanWithParent(.root, started_ns, name, .internal, attributes) catch return .{};
        return .{ .span = span, .started_ns = started_ns };
    }

    pub fn setModuleCache(self: *CompilationSession, hits: usize, misses: usize, workers: usize) void {
        if (!self.enabled) return;
        self.module_cache_hits = hits;
        self.module_cache_misses = misses;
        self.module_workers = workers;
    }

    pub fn setNativeObjects(self: *CompilationSession, reused: usize, compiled: usize) void {
        if (!self.enabled) return;
        self.native_objects_reused = reused;
        self.native_objects_compiled = compiled;
    }

    fn recordFunctionBody(self: *CompilationSession, module_name: []const u8, owner: ?[]const u8, name: []const u8, elapsed_ns: i128) void {
        if (!self.enabled or elapsed_ns <= 0) return;
        if (self.slow_function_count == self.slow_functions.len and elapsed_ns <= self.slow_functions[self.slow_function_count - 1].elapsed_ns) return;
        const full_name = if (owner) |value|
            std.fmt.allocPrint(self.allocator, "{s}.{s}.{s}", .{ module_name, value, name }) catch return
        else
            std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ module_name, name }) catch return;
        const insert_at = for (self.slow_functions[0..self.slow_function_count], 0..) |entry, index| {
            if (elapsed_ns > entry.elapsed_ns) break index;
        } else self.slow_function_count;
        if (self.slow_function_count == self.slow_functions.len) {
            self.allocator.free(self.slow_functions[self.slow_function_count - 1].name);
        } else self.slow_function_count += 1;
        var index = self.slow_function_count - 1;
        while (index > insert_at) : (index -= 1) self.slow_functions[index] = self.slow_functions[index - 1];
        self.slow_functions[insert_at] = .{ .name = full_name, .elapsed_ns = elapsed_ns };
    }

    pub fn report(self: *CompilationSession) !void {
        if (!self.enabled) return;
        const count = self.buffer.len();
        const views = try self.allocator.alloc(trace.RecordView, count);
        defer self.allocator.free(views);
        const records = self.buffer.snapshot(views);

        var starts: std.AutoHashMapUnmanaged(trace.SpanId, struct {
            timestamp_ns: i128,
            name: []const u8,
        }) = .empty;
        defer starts.deinit(self.allocator);
        var aggregates: std.StringHashMapUnmanaged(Aggregate) = .empty;
        defer aggregates.deinit(self.allocator);

        for (records) |record| switch (record.kind) {
            .span_start => try starts.put(self.allocator, record.context.span_id, .{
                .timestamp_ns = record.timestamp_ns,
                .name = record.name,
            }),
            .span_end => {
                const started = starts.get(record.context.span_id) orelse continue;
                const duration = @max(record.timestamp_ns - started.timestamp_ns, 0);
                const entry = try aggregates.getOrPut(self.allocator, started.name);
                if (!entry.found_existing) entry.value_ptr.* = .{};
                entry.value_ptr.count += 1;
                entry.value_ptr.total_ns += duration;
                entry.value_ptr.max_ns = @max(entry.value_ptr.max_ns, duration);
            },
            .event => {},
        };

        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer names.deinit(self.allocator);
        var iterator = aggregates.iterator();
        while (iterator.next()) |entry| try names.append(self.allocator, entry.key_ptr.*);
        std.mem.sort([]const u8, names.items, &aggregates, lessThanDuration);

        std.debug.print("compilation timings:\n", .{});
        for (names.items) |name| {
            const aggregate = aggregates.get(name).?;
            std.debug.print("  {s}: total {d:.3} ms, count {d}, max {d:.3} ms\n", .{
                name,
                nsToMs(aggregate.total_ns),
                aggregate.count,
                nsToMs(aggregate.max_ns),
            });
        }
        if (self.slow_function_count != 0) {
            std.debug.print("slowest semantic function bodies:\n", .{});
            for (self.slow_functions[0..self.slow_function_count]) |entry| {
                std.debug.print("  {d:.3} ms {s}\n", .{ nsToMs(entry.elapsed_ns), entry.name });
            }
        }
        if (self.module_cache_hits + self.module_cache_misses != 0) {
            std.debug.print("module cache: {d} hit, {d} miss, {d} workers\n", .{ self.module_cache_hits, self.module_cache_misses, self.module_workers });
        }
        if (self.native_objects_reused + self.native_objects_compiled != 0) {
            std.debug.print("LLVM objects: {d} reused, {d} compiled\n", .{ self.native_objects_reused, self.native_objects_compiled });
        }
        std.debug.print("trace records dropped: {d}\n", .{self.buffer.droppedCount()});
        const stats = self.cacheSnapshot();
        std.debug.print(
            "compilation cache: source {d} hit/{d} miss/{d} wait; tokens {d} hit/{d} miss/{d} wait\n",
            .{
                stats.source_hits,
                stats.source_misses,
                stats.source_waits,
                stats.token_hits,
                stats.token_misses,
                stats.token_waits,
            },
        );
    }

    pub fn cacheSnapshot(self: *const CompilationSession) CacheSnapshot {
        return .{
            .source_hits = self.cache_stats.source_hits.load(.monotonic),
            .source_misses = self.cache_stats.source_misses.load(.monotonic),
            .source_waits = self.cache_stats.source_waits.load(.monotonic),
            .token_hits = self.cache_stats.token_hits.load(.monotonic),
            .token_misses = self.cache_stats.token_misses.load(.monotonic),
            .token_waits = self.cache_stats.token_waits.load(.monotonic),
        };
    }
};

pub const Scope = struct {
    span: ?trace.Span = null,
    started_ns: i128 = 0,

    pub fn context(self: *const Scope) trace.Context {
        const span = self.span orelse return .root;
        return span.contextValue();
    }

    pub fn child(self: *const Scope, session: *CompilationSession, name: []const u8, attributes: []const telemetry.Attribute) Scope {
        if (!session.enabled) return .{};
        const started_ns = now();
        const span = session.tracer.startSpanWithParent(self.context(), started_ns, name, .internal, attributes) catch return .{};
        return .{ .span = span, .started_ns = started_ns };
    }

    pub fn end(self: *Scope) void {
        if (self.span) |*span| span.end(now(), .ok) catch {};
        self.span = null;
    }

    pub fn endFunctionBody(self: *Scope, session: *CompilationSession, module_name: []const u8, owner: ?[]const u8, name: []const u8) void {
        const ended_ns = now();
        if (self.span) |*span| span.end(ended_ns, .ok) catch {};
        if (self.span != null) session.recordFunctionBody(module_name, owner, name, ended_ns - self.started_ns);
        self.span = null;
    }

    pub fn endError(self: *Scope) void {
        if (self.span) |*span| span.end(now(), .err) catch {};
        self.span = null;
    }
};

const Aggregate = struct {
    count: usize = 0,
    total_ns: i128 = 0,
    max_ns: i128 = 0,
};

const SlowFunction = struct {
    name: []u8,
    elapsed_ns: i128,
};

const CacheState = enum(u8) {
    empty,
    loading,
    ready,
    failed,
};

const TokenTemplate = struct {
    tag: lexer.TokenTag,
    start: usize,
    len: usize,
    line: usize,
    column: usize,
    end_column: usize,
};

const CacheEntry = struct {
    path: []const u8,
    source_state: std.atomic.Value(CacheState) = .init(.empty),
    source: ?[]u8 = null,
    source_error: ?anyerror = null,
    token_state: std.atomic.Value(CacheState) = .init(.empty),
    tokens: ?[]TokenTemplate = null,
    token_error: ?anyerror = null,
};

const CacheStats = struct {
    source_hits: std.atomic.Value(u64) = .init(0),
    source_misses: std.atomic.Value(u64) = .init(0),
    source_waits: std.atomic.Value(u64) = .init(0),
    token_hits: std.atomic.Value(u64) = .init(0),
    token_misses: std.atomic.Value(u64) = .init(0),
    token_waits: std.atomic.Value(u64) = .init(0),
};

pub const CacheSnapshot = struct {
    source_hits: u64,
    source_misses: u64,
    source_waits: u64,
    token_hits: u64,
    token_misses: u64,
    token_waits: u64,
};

const Mutex = struct {
    state: std.atomic.Mutex = .unlocked,

    fn lock(self: *Mutex) void {
        while (!self.state.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Mutex) void {
        self.state.unlock();
    }
};

fn waitForState(state: *std.atomic.Value(CacheState), stored_error: *const ?anyerror) !void {
    while (true) switch (state.load(.acquire)) {
        .ready => return,
        .failed => return stored_error.* orelse error.CacheProducerFailed,
        .empty, .loading => std.atomic.spinLoopHint(),
    };
}

fn now() i128 {
    return std.Io.Clock.Timestamp.now(compat.io(), .awake).raw.nanoseconds;
}

fn nsToMs(value: i128) f64 {
    return @as(f64, @floatFromInt(value)) / @as(f64, std.time.ns_per_ms);
}

fn lessThanDuration(aggregates: *const std.StringHashMapUnmanaged(Aggregate), lhs: []const u8, rhs: []const u8) bool {
    const left = aggregates.get(lhs).?.total_ns;
    const right = aggregates.get(rhs).?.total_ns;
    if (left != right) return left > right;
    return std.mem.order(u8, lhs, rhs) == .lt;
}

const CacheTestContext = struct {
    session: *CompilationSession,
    path: []const u8,

    fn run(self: *CacheTestContext) void {
        const source = self.session.loadSource(self.path, 1024) catch unreachable;
        defer self.session.allocator.free(source);
        const tokens = self.session.lexSource(self.path, source) catch unreachable;
        defer self.session.allocator.free(tokens);
    }
};

test "compilation session single-flights immutable source and token artifacts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const file = try compat.dirCreateFile(tmp.dir, "module.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file, "const answer: i32 = 42;\n");
    }
    const path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "module.cy");
    defer std.testing.allocator.free(path);

    var session = try CompilationSession.init(std.heap.page_allocator, false);
    defer session.deinit();
    var context = CacheTestContext{ .session = &session, .path = path };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, CacheTestContext.run, .{&context});
    for (&threads) |*thread| thread.join();

    const stats = session.cacheSnapshot();
    try std.testing.expectEqual(@as(u64, 1), stats.source_misses);
    try std.testing.expectEqual(@as(u64, 3), stats.source_hits + stats.source_waits);
    try std.testing.expectEqual(@as(u64, 1), stats.token_misses);
    try std.testing.expectEqual(@as(u64, 3), stats.token_hits + stats.token_waits);
}

test "cached tokens reproduce the offsets of a direct lex" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const file = try compat.dirCreateFile(tmp.dir, "cached_offsets.cy", .{});
        defer compat.closeFile(file);
        try compat.fileWriteAll(file, "fn left(value: i32): i32 { return value; }\n");
    }
    const path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "cached_offsets.cy");
    defer std.testing.allocator.free(path);

    var session = try CompilationSession.init(std.testing.allocator, false);
    defer session.deinit();

    const source = try session.loadSource(path, 1024);
    defer session.allocator.free(source);
    const cached = try session.lexSource(path, source);
    defer session.allocator.free(cached);
    const reused = try session.lexSource(path, source);
    defer session.allocator.free(reused);
    const direct = try lexer.lexAll(session.allocator, source);
    defer session.allocator.free(direct);

    try std.testing.expectEqual(cached.len, reused.len);
    try std.testing.expectEqual(cached.len, direct.len);
    try std.testing.expect(session.cacheSnapshot().token_hits >= 1);
    for (cached, reused) |first, second| {
        try std.testing.expectEqual(first.offset, second.offset);
        try std.testing.expectEqual(first.end_offset, second.end_offset);
    }
    for (cached, direct) |first, second| {
        try std.testing.expectEqual(first.offset, second.offset);
        try std.testing.expectEqual(first.end_offset, second.end_offset);
        try std.testing.expectEqualStrings(first.lexeme, second.lexeme);
    }

    // A cached token with no offset would collapse every method use of a
    // declaration onto the same record, so at least one token must report one.
    var reported_offset = false;
    for (reused) |token| {
        if (token.offset != 0) reported_offset = true;
    }
    try std.testing.expect(reported_offset);
}

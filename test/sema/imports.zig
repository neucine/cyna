const std = @import("std");
const compat = @import("cyna").compat;

const compiler = @import("cyna").compiler;
const diagnostics = compiler.diagnostics;
const helpers = @import("../helpers.zig");
const lower = compiler.lower;
const sema = compiler.sema;

test "relative free function imports resolve inside path dependency" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "app/src");
    try compat.dirMakePath(tmp.dir, "core/src/pipeline");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "app/cyna.toml", .data =
        \\name = "lookup_app"
        \\entry = "src/lib.cy"
        \\[dependencies]
        \\lookup_core = { path = "../core" }
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "app/src/lib.cy", .data =
        \\import lookup_core.pipeline.first;
        \\import lookup_core.pipeline.second;
        \\pub fn run(): usize { return second.composed(first.requirements(3)); }
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "core/cyna.toml", .data =
        \\name = "lookup_core"
        \\entry = "src/lib.cy"
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "core/src/lib.cy", .data =
        \\import .pipeline.first;
        \\import .pipeline.second;
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "core/src/pipeline/first.cy", .data =
        \\pub fn requirements(width: usize): usize { return width + 1; }
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "core/src/pipeline/second.cy", .data =
        \\import .pipeline.first;
        \\pub fn composed(width: usize): usize { return first.requirements(width); }
    });
    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "app/src/lib.cy");
    defer std.testing.allocator.free(root);
    var loaded = try compiler.loader.loadProgram(std.testing.allocator, root);
    defer loaded.deinit(std.testing.allocator);
    const module = try sema.buildSir(std.testing.allocator, root, loaded.program);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(sema.findFunction(module, "run") != null);
}

test "package type aliases and public signatures preserve owner identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirMakePath(tmp.dir, "app/src");
    try compat.dirMakePath(tmp.dir, "core/src");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "app/cyna.toml", .data =
        \\name = "identity_app"
        \\entry = "src/lib.cy"
        \\[dependencies]
        \\identity_core = { path = "../core" }
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "core/cyna.toml", .data =
        \\name = "identity_core"
        \\entry = "src/api.cy"
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "core/src/types.cy", .data =
        \\pub enum E: i32 { a = 0 }
        \\pub struct Box { pub tag: E; }
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "core/src/api.cy", .data =
        \\import { E, Box } from .types;
        \\pub fn identity(value: E): E { return value; }
        \\pub fn make(): Box { return Box { tag: E.a }; }
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "core/src/facade.cy", .data =
        \\import .types;
        \\pub type PublicE = types.E;
        \\pub type PublicBox = types.Box;
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "app/src/lib.cy", .data =
        \\import { E, Box } from identity_core.types;
        \\import { identity, make } from identity_core.api;
        \\import { PublicE, PublicBox } from identity_core.facade;
        \\pub fn original(value: E): Box { return make(); }
        \\pub fn exposed(value: PublicE): PublicBox { return make(); }
        \\pub fn run(): E {
        \\    const e: PublicE = identity(E.a);
        \\    const box: PublicBox = original(e);
        \\    const owner: Box = box;
        \\    return owner.tag;
        \\}
    });
    const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "app/src/lib.cy");
    defer std.testing.allocator.free(root);
    var loaded = try compiler.loader.loadProgram(std.testing.allocator, root);
    defer loaded.deinit(std.testing.allocator);
    const module = try sema.buildSir(std.testing.allocator, root, loaded.program);
    defer module.deinit(std.testing.allocator);
    const original = sema.findFunction(module, "original") orelse return error.TestExpectedEqual;
    const exposed = sema.findFunction(module, "exposed") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(original.params[0].type_id.?, exposed.params[0].type_id.?);
}

test "syntax roles respect imported generic method identities and visibility" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data = "name = \"syntax-imports\"\nsrc = \".\"\nentry = \"main.cy\"\n" });
    for ([_][]const u8{ "pub", "" }) |visibility| {
        const source = try std.fmt.allocPrint(std.testing.allocator,
            \\pub struct Bag<T> {{
            \\    pub data: [:]T;
            \\    @syntax.index {s} fn fetch(self: &const Bag<T>, key: usize): &const T {{ return &self.data[key]; }}
            \\    @syntax.iter pub fn begin(self: &const Bag<T>): usize {{ return 0; }}
            \\    @syntax.iter_has_next pub fn more(self: &const Bag<T>, state: &const usize): bool {{ return state < self.data.len(); }}
            \\    @syntax.iter_next pub fn advance(self: &const Bag<T>, state: &usize): usize {{ const cursor: usize = state; state = state + 1; return cursor; }}
            \\    @syntax.iter_item {s} fn element(self: &const Bag<T>, cursor: usize): &const T {{ return &self.data[cursor]; }}
            \\}}
        , .{ visibility, visibility });
        defer std.testing.allocator.free(source);
        try compat.dirWriteFile(tmp.dir, .{ .sub_path = "model.cy", .data = source });
        for ([_][]const u8{
            "import { Bag as Renamed } from .model; fn main(): i32 { const bag: Renamed<i32> = { data: [42] }; return bag[0]; }",
            "import .model as source; fn main(): i32 { const bag: source.Bag<i32> = { data: [42] }; for item in bag { return item; } return 0; }",
        }) |main_source| {
            try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = main_source });
            const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
            defer std.testing.allocator.free(root);
            var loaded = try compiler.loader.loadProgram(std.testing.allocator, root);
            defer loaded.deinit(std.testing.allocator);
            if (visibility.len != 0) {
                const module = try sema.buildSir(std.testing.allocator, root, loaded.program);
                defer module.deinit(std.testing.allocator);
            } else try std.testing.expectError(error.SemanticFailed, sema.buildSir(std.testing.allocator, root, loaded.program));
        }
    }
}

test "ordinary clone methods can be called through imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data = "name = \"clone-imports\"\nsrc = \".\"\nentry = \"main.cy\"\n" });
    for ([_][]const u8{"pub"}) |visibility| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "pub struct Box {{ pub data: [:]i32; {s} fn duplicate(self: &const Box): Box {{ return Box {{ data: self.data.clone() }}; }} }}", .{visibility});
        defer std.testing.allocator.free(source);
        try compat.dirWriteFile(tmp.dir, .{ .sub_path = "model.cy", .data = source });
        try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
            \\import .model;
            \\fn main(): i32 { const original: model.Box = { data: [42] }; const other = original.duplicate(); return other.data[0]; }
        });
        const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
        defer std.testing.allocator.free(root);
        var loaded = try compiler.loader.loadProgram(std.testing.allocator, root);
        defer loaded.deinit(std.testing.allocator);
        const module = try sema.buildSir(std.testing.allocator, root, loaded.program);
        defer module.deinit(std.testing.allocator);
    }
}

test "slice view attributes respect imported method visibility" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data = "name = \"slice-imports\"\nsrc = \".\"\nentry = \"main.cy\"\n" });
    const methods = [_][]const u8{ "pub", "" };
    for (methods) |visibility| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "pub struct Bag<T> {{ pub data: [:]T; @syntax.slice_view {s} fn inspect(self: &const Bag<T>): []const T {{ return self.data[..]; }} }}", .{visibility});
        defer std.testing.allocator.free(source);
        try compat.dirWriteFile(tmp.dir, .{ .sub_path = "model.cy", .data = source });
        try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
            \\import .model;
            \\fn main(): i32 { const bag: model.Bag<i32> = { data: [21, 42] }; const view = bag[1..]; return view[0]; }
        });
        const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
        defer std.testing.allocator.free(root);
        var loaded = try compiler.loader.loadProgram(std.testing.allocator, root);
        defer loaded.deinit(std.testing.allocator);
        if (visibility.len != 0) {
            const module = try sema.buildSir(std.testing.allocator, root, loaded.program);
            defer module.deinit(std.testing.allocator);
        } else try std.testing.expectError(error.SemanticFailed, sema.buildSir(std.testing.allocator, root, loaded.program));
    }
}

test "sequence literal factories respect imports and declaration identities" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data = "name = \"sequence-imports\"\nsrc = \".\"\nentry = \"main.cy\"\n" });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "factory.cy", .data =
        \\pub struct Batch<T> { pub storage: [:]T; }
        \\@syntax.sequence_literal
        \\pub fn collect<T>(items: [:]T): Batch<T> { return Batch<T> { storage: items }; }
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "other.cy", .data =
        \\pub struct Batch<T> { pub storage: [:]T; }
        \\@syntax.sequence_literal
        \\pub fn collect<T>(items: [:]T): Batch<T> { return Batch<T> { storage: items }; }
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "bridge.cy", .data =
        \\import .factory as source;
        \\pub type PublicBatch = source.Batch<i32>;
        \\pub fn ping(): i32 { return 0; }
    });
    const cases = [_]struct { source: []const u8, succeeds: bool }{
        .{ .source = "import .factory as source; import .other as alternate; fn main(): i32 { const a: source.Batch<i32> = [1]; const b: alternate.Batch<i32> = []; return 0; }", .succeeds = true },
        .{ .source = "import { Batch, collect as renamed } from .factory; fn main(): i32 { const a: Batch<i32> = []; return 0; }", .succeeds = true },
        .{ .source = "import { Batch } from .factory; fn main(): i32 { const a: Batch<i32> = []; return 0; }", .succeeds = false },
        .{ .source = "import .bridge; fn main(): i32 { const a: bridge.PublicBatch = []; return 0; }", .succeeds = false },
    };
    for (cases) |case| {
        try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data = case.source });
        const root = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
        defer std.testing.allocator.free(root);
        var loaded = try compiler.loader.loadProgram(std.testing.allocator, root);
        defer loaded.deinit(std.testing.allocator);
        if (case.succeeds) {
            const module = try sema.buildSirWithOptions(std.testing.allocator, root, loaded.program, .{ .diagnostic_context = .{} });
            defer module.deinit(std.testing.allocator);
        } else {
            try std.testing.expectError(error.SemanticFailed, sema.buildSir(std.testing.allocator, root, loaded.program));
        }
    }
}

test "backticks escape keyword module path segments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "cyna.toml",
        .data =
        \\name = "escaped-module-test"
        \\src = "."
        \\entry = "main.cy"
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "type.cy",
        .data =
        \\pub const answer: i32 = 42;
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "main.cy",
        .data =
        \\import .`type` as data;
        \\
        \\fn main(): i32 {
        \\    return data.answer;
        \\}
        \\
        ,
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);
    var loaded = try compiler.loader.loadProgram(std.testing.allocator, source_path);
    defer loaded.deinit(std.testing.allocator);
    const module = try sema.buildSir(std.testing.allocator, source_path, loaded.program);
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(sema.findFunction(module, "main") != null);
}

test "module-qualified imported type names resolve in signatures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "cyna.toml",
        .data =
        \\name = "qualified-type-test"
        \\src = "."
        \\entry = "main.cy"
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "model.cy",
        .data =
        \\pub struct Region {
        \\    pub start: usize;
        \\}
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "main.cy",
        .data =
        \\import .model as data;
        \\
        \\fn start(region: data.Region): usize {
        \\    return region.start;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        \\
        ,
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);
    var loaded = try compiler.loader.loadProgram(std.testing.allocator, source_path);
    defer loaded.deinit(std.testing.allocator);
    const module = try sema.buildSir(std.testing.allocator, source_path, loaded.program);
    defer module.deinit(std.testing.allocator);

    const start = sema.findFunction(module, "start") orelse return error.TestExpectedEqual;
    const param_type = try module.canonical_types.?.get(start.params[0].type_id.?);
    try std.testing.expect(param_type.* == .nominal);
    var resolved_region = false;
    for (module.structs) |decl| {
        if (decl.decl_id == param_type.nominal.decl_id) {
            try std.testing.expectEqualStrings("Region", decl.name);
            try std.testing.expectEqualStrings("model", decl.module_name);
            resolved_region = true;
            break;
        }
    }
    try std.testing.expect(resolved_region);
}

test "private module-qualified generic struct reports access diagnostic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "cyna.toml",
        .data =
        \\name = "private-qualified-generic-test"
        \\src = "."
        \\entry = "main.cy"
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "model.cy",
        .data =
        \\struct Box<T> {
        \\    pub value: T;
        \\}
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "main.cy",
        .data =
        \\import .model;
        \\
        \\struct Holder {
        \\    box: model.Box<i32>;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        \\
        ,
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);

    try helpers.expectModuleSemanticFailedMessage(std.testing.allocator, source_path, "type `Box` is not public in imported module");
}

test "same-named functions in imported modules retain distinct identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "cyna.toml",
        .data =
        \\name = "function-identity-test"
        \\src = "."
        \\entry = "main.cy"
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "left.cy",
        .data =
        \\pub fn value(): i32 {
        \\    return 1;
        \\}
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "right.cy",
        .data =
        \\pub fn value(): i32 {
        \\    return 2;
        \\}
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "main.cy",
        .data =
        \\import .left;
        \\import .right;
        \\
        \\fn main(): i32 {
        \\    return left.value() + right.value();
        \\}
        \\
        ,
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);
    var loaded = try compiler.loader.loadProgram(std.testing.allocator, source_path);
    defer loaded.deinit(std.testing.allocator);
    var left_source: ?[]const u8 = null;
    var right_source: ?[]const u8 = null;
    for (loaded.program.module_infos) |info| {
        if (std.mem.eql(u8, info.name, "left")) left_source = info.source_path;
        if (std.mem.eql(u8, info.name, "right")) right_source = info.source_path;
    }
    try std.testing.expect(left_source != null);
    try std.testing.expect(right_source != null);
    try std.testing.expect(!std.mem.eql(u8, left_source.?, right_source.?));

    const module = try sema.buildSir(std.testing.allocator, source_path, loaded.program);
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(sema.findFunction(module, "main") != null);
}

test "same-named enum and struct imports keep their declaration kinds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "cyna.toml",
        .data =
        \\name = "cross-kind-imports"
        \\src = "."
        \\entry = "main.cy"
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "left.cy",
        .data =
        \\pub enum MemoryOrder: i32 {
        \\    relaxed = 0,
        \\    acquire,
        \\}
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "right.cy",
        .data =
        \\pub struct MemoryOrder {
        \\    pub peak_bytes: usize;
        \\}
        \\
        \\pub fn value(): MemoryOrder {
        \\    return MemoryOrder { peak_bytes: 42 };
        \\}
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "main.cy",
        .data =
        \\import { MemoryOrder as OrderKind } from .left;
        \\import { MemoryOrder as PeakOrder, value } from .right;
        \\
        \\fn main(): usize {
        \\    const kind = OrderKind.relaxed;
        \\    if kind == OrderKind.relaxed {
        \\        const order: PeakOrder = value();
        \\        return order.peak_bytes;
        \\    }
        \\    return 0;
        \\}
        \\
        ,
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);
    var loaded = try compiler.loader.loadProgram(std.testing.allocator, source_path);
    defer loaded.deinit(std.testing.allocator);
    const module = try sema.buildSir(std.testing.allocator, source_path, loaded.program);
    defer module.deinit(std.testing.allocator);

    const lowered = try lower.lowerModule(std.testing.allocator, module);
    defer lowered.deinit(std.testing.allocator);
}

test "transitive module types are not visible without an import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "cyna.toml",
        .data =
        \\name = "transitive-type-visibility"
        \\src = "."
        \\entry = "main.cy"
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "model.cy",
        .data =
        \\pub struct Region {
        \\    pub start: usize;
        \\}
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "bridge.cy",
        .data =
        \\import .model;
        \\
        \\pub fn start(region: model.Region): usize {
        \\    return region.start;
        \\}
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "main.cy",
        .data =
        \\import .bridge;
        \\
        \\fn read(region: Region): usize {
        \\    return region.start;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        \\
        ,
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);
    var loaded = try compiler.loader.loadProgram(std.testing.allocator, source_path);
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectError(error.SemanticFailed, sema.buildSir(std.testing.allocator, source_path, loaded.program));
}

test "imported function signatures resolve in their declaration module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data =
        \\name = "function-signature-context"
        \\src = "."
        \\entry = "main.cy"
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "model.cy", .data =
        \\pub struct Choice {
        \\    pub value: usize;
        \\}
        \\
        \\pub fn make(): Choice {
        \\    return Choice { value: 7 };
        \\}
        \\
        \\pub fn read(choice: &const Choice): usize {
        \\    return choice.value;
        \\}
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "consumer.cy", .data =
        \\import { make, read } from .model;
        \\
        \\pub fn run(): usize {
        \\    const choice = make();
        \\    return read(&choice);
        \\}
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import { run } from .consumer;
        \\fn main(): usize { return run(); }
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);
    var loaded = try compiler.loader.loadProgram(std.testing.allocator, source_path);
    defer loaded.deinit(std.testing.allocator);
    const module = try sema.buildSir(std.testing.allocator, source_path, loaded.program);
    defer module.deinit(std.testing.allocator);
}

test "explicit generic method arguments resolve in the caller module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data =
        \\name = "generic-method-caller-context"
        \\src = "."
        \\entry = "main.cy"
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "model.cy", .data =
        \\pub struct Box {
        \\    pub value: usize;
        \\
        \\    pub fn pass<U>(self: Box, value: U): U {
        \\        return value;
        \\    }
        \\}
        \\
        \\pub fn make(): Box {
        \\    return Box { value: 7 };
        \\}
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "consumer.cy", .data =
        \\import { make } from .model;
        \\
        \\struct Secret {
        \\    pub value: usize;
        \\}
        \\
        \\pub fn run(secret: Secret): Secret {
        \\    const box = make();
        \\    return box.pass<Secret>(secret);
        \\}
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import { run } from .consumer;
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);
    var loaded = try compiler.loader.loadProgram(std.testing.allocator, source_path);
    defer loaded.deinit(std.testing.allocator);
    const module = try sema.buildSir(std.testing.allocator, source_path, loaded.program);
    defer module.deinit(std.testing.allocator);
}

test "imported union payloads resolve in their declaration module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "cyna.toml", .data =
        \\name = "union-payload-context"
        \\src = "."
        \\entry = "main.cy"
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "model.cy", .data =
        \\pub struct Payload {
        \\    pub value: usize;
        \\}
        \\
        \\pub union Choice {
        \\    value: Payload;
        \\}
        \\
        \\pub fn make(): Choice {
        \\    return .value(Payload { value: 7 });
        \\}
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "consumer.cy", .data =
        \\import { make } from .model;
        \\
        \\pub fn run(): usize {
        \\    const choice = make();
        \\    switch choice {
        \\        .value(payload) => { return payload.value; }
        \\    }
        \\}
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import { run } from .consumer;
        \\fn main(): usize { return run(); }
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);
    var loaded = try compiler.loader.loadProgram(std.testing.allocator, source_path);
    defer loaded.deinit(std.testing.allocator);
    const module = try sema.buildSir(std.testing.allocator, source_path, loaded.program);
    defer module.deinit(std.testing.allocator);
}

test "same-named nominal types in imported modules lower by identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "cyna.toml",
        .data =
        \\name = "nominal-identity-test"
        \\src = "."
        \\entry = "main.cy"
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "spec.cy",
        .data =
        \\pub protocol Scored {
        \\    fn score(self: &const Self): i32;
        \\}
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "left.cy",
        .data =
        \\import .spec;
        \\
        \\pub struct Item {
        \\    pub value: i32;
        \\    pub extra: i32;
        \\    pub fn tail(self: &const Item): i32 { return self.extra; }
        \\}
        \\
        \\impl Item: spec.Scored {
        \\    fn score(self: &const Item): i32 { return self.value + self.extra; }
        \\}
        \\
        \\pub enum Status: i8 {
        \\    ready,
        \\}
        \\
        \\pub union Payload {
        \\    number: i32;
        \\}
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "right.cy",
        .data =
        \\import .spec;
        \\
        \\pub struct Item {
        \\    pub value: bool;
        \\    pub fn tail(self: &const Item): bool { return self.value; }
        \\}
        \\
        \\impl Item: spec.Scored {
        \\    fn score(self: &const Item): i32 { if self.value { return 1; } return 0; }
        \\}
        \\
        \\pub enum Status: i32 {
        \\    ready,
        \\}
        \\
        \\pub union Payload {
        \\    text: string;
        \\}
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "main.cy",
        .data =
        \\import .left;
        \\import .right;
        \\
        \\fn use_left(item: left.Item, status: left.Status, payload: left.Payload): i32 {
        \\    return item.value;
        \\}
        \\
        \\fn use_right(item: right.Item, status: right.Status, payload: right.Payload): bool {
        \\    return item.value;
        \\}
        \\
        \\fn main(): i32 {
        \\    const left_item: left.Item = { value: 1, extra: 2 };
        \\    const right_item: right.Item = { value: true };
        \\    const left_tail: i32 = left_item.tail();
        \\    const left_score: i32 = left_item.score();
        \\    const left_status: left.Status = .ready;
        \\    const right_status: right.Status = .ready;
        \\    const _ = left_status;
        \\    const _ = right_status;
        \\    if right_item.tail() { return left_tail + left_score + right_item.score(); }
        \\    return 0;
        \\}
        \\
        ,
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);
    var loaded = try compiler.loader.loadProgram(std.testing.allocator, source_path);
    defer loaded.deinit(std.testing.allocator);
    const module = try sema.buildSir(std.testing.allocator, source_path, loaded.program);
    defer module.deinit(std.testing.allocator);

    const use_left = sema.findFunction(module, "use_left") orelse return error.TestExpectedEqual;
    const use_right = sema.findFunction(module, "use_right") orelse return error.TestExpectedEqual;
    for (use_left.params, use_right.params) |left_param, right_param| {
        const left_node = try module.canonical_types.?.get(left_param.type_id.?);
        const right_node = try module.canonical_types.?.get(right_param.type_id.?);
        try std.testing.expect(left_node.* == .nominal);
        try std.testing.expect(right_node.* == .nominal);
        try std.testing.expect(left_node.nominal.decl_id != right_node.nominal.decl_id);
    }

    const lowered = try lower.lowerModule(std.testing.allocator, module);
    defer lowered.deinit(std.testing.allocator);
}

test "same-named generic instances in imported modules resolve methods by identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "cyna.toml",
        .data = "name = \"generic-nominal-identity-test\"\nsrc = \".\"\nentry = \"main.cy\"\n",
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "left.cy",
        .data =
        \\pub struct Box<T> {
        \\    pub value: T;
        \\    pub fn get(self: &const Box<T>): T { return self.value; }
        \\    @syntax.index pub fn at(self: &const Box<T>, key: usize): &const T { const _ = key; return &self.value; }
        \\}
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "right.cy",
        .data =
        \\pub struct Box<T> {
        \\    pub enabled: T;
        \\    pub fn get(self: &const Box<T>): T { return self.enabled; }
        \\    @syntax.index pub fn at(self: &const Box<T>, key: usize): &const T { const _ = key; return &self.enabled; }
        \\}
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "main.cy",
        .data =
        \\import .left;
        \\import .right;
        \\
        \\fn main(): i32 {
        \\    const l: left.Box<i32> = { value: 41 };
        \\    const r: right.Box<i32> = { enabled: 1 };
        \\    return l.get() + r.get() + l[0] + r[0];
        \\}
        \\
        ,
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);
    var loaded = try compiler.loader.loadProgram(std.testing.allocator, source_path);
    defer loaded.deinit(std.testing.allocator);
    const module = try sema.buildSir(std.testing.allocator, source_path, loaded.program);
    defer module.deinit(std.testing.allocator);

    const lowered = try lower.lowerModule(std.testing.allocator, module);
    defer lowered.deinit(std.testing.allocator);
}

test "same-named distinct aliases in imported modules compare by identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "cyna.toml",
        .data =
        \\name = "alias-identity-test"
        \\src = "."
        \\entry = "main.cy"
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "left.cy",
        .data =
        \\pub type Code = distinct i32;
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "right.cy",
        .data =
        \\pub type Code = distinct i32;
        \\
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "main.cy",
        .data =
        \\import .left;
        \\import .right;
        \\
        \\fn take_right(value: right.Code): i32 {
        \\    return 0;
        \\}
        \\
        \\fn main(): i32 {
        \\    const value: left.Code = 1 as left.Code;
        \\    return take_right(value);
        \\}
        \\
        ,
    });

    const source_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(source_path);
    var loaded = try compiler.loader.loadProgram(std.testing.allocator, source_path);
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectError(error.SemanticFailed, sema.buildSir(std.testing.allocator, source_path, loaded.program));
}

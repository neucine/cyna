const std = @import("std");
const ast = @import("../compiler/parser/ast.zig");
const loader = @import("../compiler/loader.zig");

pub const Error = error{InvalidModulePlan};

/// Borrowed view of the loader's module graph. The plan owns only the module
/// array; all strings and import declarations remain owned by LoadedProgram.
pub const Module = struct {
    name: []const u8,
    source_path: []const u8,
    source: []const u8,
    imports: []const ast.ImportDecl,
    autoload: bool,
    has_generic_declarations: bool = false,
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    modules: []Module,

    pub fn init(allocator: std.mem.Allocator, loaded: loader.LoadedProgram) !Plan {
        if (loaded.module_names.len != loaded.source_paths.len or
            loaded.module_names.len != loaded.sources.len or
            loaded.module_names.len != loaded.program.module_infos.len)
        {
            return error.InvalidModulePlan;
        }

        const modules = try allocator.alloc(Module, loaded.module_names.len);
        errdefer allocator.free(modules);
        for (modules, loaded.module_names, loaded.source_paths, loaded.sources, loaded.program.module_infos) |*module, name, source_path, source, info| {
            module.* = .{
                .name = name,
                .source_path = source_path,
                .source = source,
                .imports = info.imports,
                .autoload = info.autoload,
                .has_generic_declarations = moduleHasGenericDeclarations(loaded.program, name),
            };
        }
        return .{ .allocator = allocator, .modules = modules };
    }

    pub fn deinit(self: *Plan) void {
        self.allocator.free(self.modules);
        self.* = undefined;
    }

    pub fn updateHash(self: Plan, hasher: *std.crypto.hash.sha2.Sha256) void {
        hasher.update("cyna-module-plan-v1\x00");
        for (self.modules) |module| {
            hashString(hasher, module.name);
            hashString(hasher, module.source_path);
            hasher.update(module.source);
            hasher.update("\x00");
            for (module.imports) |import_decl| {
                hashString(hasher, import_decl.path);
                hashString(hasher, if (import_decl.is_root_package) "root" else "package");
                hashString(hasher, import_decl.local_name orelse "");
                for (import_decl.items) |item| {
                    hashString(hasher, item.name);
                    hashString(hasher, item.local_name orelse "");
                }
                hasher.update("\x01");
            }
            hasher.update("\x02");
        }
    }

    pub fn moduleIndex(self: Plan, name: []const u8) ?usize {
        for (self.modules, 0..) |module, index| {
            if (std.mem.eql(u8, module.name, name)) return index;
        }
        return null;
    }

    pub fn updateModuleHash(self: Plan, allocator: std.mem.Allocator, hasher: *std.crypto.hash.sha2.Sha256, root_index: usize) !void {
        if (root_index >= self.modules.len) return error.InvalidModulePlan;
        const visited = try allocator.alloc(bool, self.modules.len);
        defer allocator.free(visited);
        @memset(visited, false);
        try self.visitDependencies(root_index, visited);
        for (self.modules, 0..) |module, index| {
            if (module.autoload) try self.visitDependencies(index, visited);
        }
        hasher.update("cyna-module-closure-v1\x00");
        for (self.modules, 0..) |module, index| {
            if (!visited[index]) continue;
            hashModule(hasher, module);
        }
    }

    fn visitDependencies(self: Plan, index: usize, visited: []bool) !void {
        if (visited[index]) return;
        visited[index] = true;
        for (self.modules[index].imports) |import_decl| {
            const imported_name = normalizeImportName(import_decl.path);
            const dependency_index = self.moduleIndex(imported_name) orelse continue;
            try self.visitDependencies(dependency_index, visited);
        }
    }

    fn hashModule(hasher: *std.crypto.hash.sha2.Sha256, module: Module) void {
        hashString(hasher, module.name);
        hashString(hasher, module.source_path);
        hasher.update(module.source);
        hasher.update("\x00");
        for (module.imports) |import_decl| {
            hashString(hasher, import_decl.path);
            hashString(hasher, if (import_decl.is_root_package) "root" else "package");
            hashString(hasher, import_decl.local_name orelse "");
            for (import_decl.items) |item| {
                hashString(hasher, item.name);
                hashString(hasher, item.local_name orelse "");
            }
            hasher.update("\x01");
        }
        hasher.update("\x02");
    }

    fn normalizeImportName(path: []const u8) []const u8 {
        return if (std.mem.startsWith(u8, path, ".")) path[1..] else path;
    }

    fn hashString(hasher: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
        hasher.update(value);
        hasher.update("\x00");
    }
};

fn moduleHasGenericDeclarations(program: ast.Program, module_name: []const u8) bool {
    for (program.functions) |function| {
        if (function.type_params.len != 0 and std.mem.eql(u8, function.module_name, module_name)) return true;
    }
    for (program.structs) |decl| {
        if (!std.mem.eql(u8, decl.module_name, module_name)) continue;
        if (decl.type_params.len != 0) return true;
        for (decl.methods) |method| {
            if (method.type_params.len != 0) return true;
        }
    }
    for (program.impls) |decl| {
        if (!std.mem.eql(u8, decl.module_name, module_name)) continue;
        if (decl.type_params.len != 0) return true;
        for (decl.methods) |method| {
            if (method.type_params.len != 0) return true;
        }
    }
    return false;
}

test "module plan lookup handles known and missing modules" {
    const modules = [_]Module{
        .{ .name = "main", .source_path = "main.cy", .source = "", .imports = &.{}, .autoload = false },
    };
    var plan = Plan{ .allocator = std.testing.allocator, .modules = try std.testing.allocator.dupe(Module, &modules) };
    defer plan.deinit();
    try std.testing.expectEqual(@as(?usize, 0), plan.moduleIndex("main"));
    try std.testing.expect(plan.moduleIndex("missing") == null);
}

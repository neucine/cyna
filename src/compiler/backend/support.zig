const std = @import("std");
const common = @import("llvm/common.zig");
const lir = @import("../lower/lir.zig");
const package_manifest = @import("../package.zig");
pub const symbols = @import("../../runtime/symbols.zig");

pub const Error = common.Error;
pub const ArtifactDeps = struct {
    runtime: bool = false,
    std: bool = false,

    pub fn any(self: ArtifactDeps) bool {
        return self.runtime or self.std;
    }
};

pub const Reachability = struct {
    function_reachable: []bool,

    pub fn deinit(self: Reachability, allocator: std.mem.Allocator) void {
        allocator.free(self.function_reachable);
    }

    pub fn functionIsReachable(self: Reachability, index: usize) bool {
        return self.function_reachable[index];
    }
};

pub fn analyzeReachability(allocator: std.mem.Allocator, module: lir.Module) Error!Reachability {
    const reachable = try allocator.alloc(bool, module.functions.len);
    errdefer allocator.free(reachable);
    @memset(reachable, false);

    var worklist: std.ArrayListUnmanaged(usize) = .empty;
    defer worklist.deinit(allocator);

    for (module.functions, 0..) |function, index| {
        if (isRootFunction(function)) {
            try markReachable(allocator, reachable, &worklist, index);
        }
    }
    for (module.globals) |global| {
        if (global.init) |init| {
            try markReachableGlobalInitSymbols(allocator, module, reachable, &worklist, init);
        }
    }

    while (worklist.pop()) |index| {
        const function = module.functions[index];
        for (function.blocks) |block| {
            for (block.instructions) |inst| {
                switch (inst.data) {
                    .call => |call| if (findFunctionIndexByCallName(module, call.name)) |callee_index| {
                        try markReachable(allocator, reachable, &worklist, callee_index);
                    },
                    .global_addr => |name| if (findFunctionIndexByCallName(module, name)) |callee_index| {
                        try markReachable(allocator, reachable, &worklist, callee_index);
                    },
                    else => {},
                }
            }
        }
    }

    return .{ .function_reachable = reachable };
}

pub fn allFunctionsReachable(allocator: std.mem.Allocator, module: lir.Module) Error!Reachability {
    const reachable = try allocator.alloc(bool, module.functions.len);
    @memset(reachable, true);
    return .{ .function_reachable = reachable };
}

fn markReachableGlobalInitSymbols(
    allocator: std.mem.Allocator,
    module: lir.Module,
    reachable: []bool,
    worklist: *std.ArrayListUnmanaged(usize),
    init: lir.GlobalInit,
) Error!void {
    switch (init) {
        .symbol_addr => |name| if (findFunctionIndexByCallName(module, name)) |index| {
            try markReachable(allocator, reachable, worklist, index);
        },
        .some => |value| try markReachableGlobalInitSymbols(allocator, module, reachable, worklist, value.*),
        .@"union" => |value| if (value.payload) |payload| {
            try markReachableGlobalInitSymbols(allocator, module, reachable, worklist, payload.*);
        },
        .array => |items| for (items) |item| {
            try markReachableGlobalInitSymbols(allocator, module, reachable, worklist, item);
        },
        .@"struct" => |fields| for (fields) |field| {
            try markReachableGlobalInitSymbols(allocator, module, reachable, worklist, field);
        },
        else => {},
    }
}

fn isRootFunction(function: lir.Function) bool {
    if (function.is_extern) return false;
    if (function.is_export) return true;
    if (std.mem.eql(u8, function.name, "main")) return true;
    if (function.is_test_entry) return true;
    return false;
}

fn markReachable(
    allocator: std.mem.Allocator,
    reachable: []bool,
    worklist: *std.ArrayListUnmanaged(usize),
    index: usize,
) Error!void {
    if (reachable[index]) return;
    reachable[index] = true;
    try worklist.append(allocator, index);
}

fn functionReachable(reachability: ?Reachability, index: usize) bool {
    return if (reachability) |value| value.functionIsReachable(index) else true;
}

pub fn moduleUsesStringCmp(module: lir.Module, reachability: ?Reachability) bool {
    for (module.functions, 0..) |function, index| {
        if (!functionReachable(reachability, index)) continue;
        for (function.blocks) |block| {
            for (block.instructions) |inst| {
                if (inst.data == .string_cmp) return true;
            }
        }
    }
    return false;
}

pub fn moduleUsesContainerRuntimeDecl(module: lir.Module, reachability: ?Reachability, name: []const u8) bool {
    for (module.functions, 0..) |function, index| {
        if (!functionReachable(reachability, index)) continue;
        for (function.blocks) |block| {
            for (block.instructions) |inst| {
                if (instUsesContainerRuntimeDecl(inst.data, name)) return true;
            }
        }
    }
    return false;
}

fn instUsesContainerRuntimeDecl(data: lir.InstData, name: []const u8) bool {
    return switch (data) {
        .call => |call| std.mem.eql(u8, call.name, name),
        .sequence_cmp => std.mem.eql(u8, name, symbols.sequence_eq_symbol),
        .sparse_cmp => std.mem.eql(u8, name, symbols.sparse_eq_symbol),
        .dense_new => false,
        .dense_copy => false,
        .dense_len => false,
        .dense_clear => false,
        .dense_reserve => false,
        .dense_data => false,
        .dense_at => false,
        .dense_push => false,
        .dense_push_move => false,
        .dense_pop => false,
        .dense_drop => false,
        .sparse_new => false,
        .sparse_copy => false,
        .sparse_drop => false,
        .sparse_len => false,
        .sparse_capacity => false,
        .sparse_clear => false,
        .sparse_indices => false,
        .sparse_contains_index => false,
        .sparse_payload_ptr => false,
        .sparse_get => false,
        .sparse_set => false,
        .sparse_set_move => false,
        .sparse_insert => false,
        .sparse_insert_move => false,
        .sparse_take => false,
        else => false,
    };
}

pub fn moduleUsesCallNamed(module: lir.Module, reachability: ?Reachability, name: []const u8) bool {
    for (module.functions, 0..) |function, index| {
        if (!functionReachable(reachability, index)) continue;
        for (function.blocks) |block| {
            for (block.instructions) |inst| {
                switch (inst.data) {
                    .call => |call| if (std.mem.eql(u8, call.name, name)) return true,
                    else => {},
                }
            }
        }
    }
    return false;
}

pub fn moduleUsesAnyRuntimeCallNamed(module: lir.Module, reachability: ?Reachability, decls: []const symbols.RuntimeDecl) bool {
    for (decls) |decl| {
        const symbol_name = symbols.name(decl.id);
        if (moduleUsesCallNamed(module, reachability, symbol_name) or moduleUsesContainerRuntimeDecl(module, reachability, symbol_name)) return true;
    }
    return false;
}

pub fn moduleUsesAnyStdCallNamed(module: lir.Module, reachability: ?Reachability, decls: []const package_manifest.AbiDecl) bool {
    for (decls) |decl| {
        if (moduleUsesCallNamed(module, reachability, decl.name)) return true;
    }
    return false;
}

pub fn moduleUsesAnyCall(module: lir.Module, reachability: ?Reachability, names: []const []const u8) bool {
    for (names) |name| {
        if (moduleUsesCallNamed(module, reachability, name)) return true;
    }
    return false;
}

pub fn moduleArtifactDeps(allocator: std.mem.Allocator, module: lir.Module) ArtifactDeps {
    const reachability = analyzeReachability(allocator, module) catch null;
    defer if (reachability) |value| value.deinit(allocator);
    return moduleArtifactDepsWithReachability(allocator, module, reachability);
}

pub fn moduleArtifactDepsWithReachability(allocator: std.mem.Allocator, module: lir.Module, reachability: ?Reachability) ArtifactDeps {
    var deps: ArtifactDeps = .{};

    if (moduleUsesStringCmp(module, reachability) or
        moduleUsesAnyRuntimeCallNamed(module, reachability, &symbols.string_runtime_decls) or
        moduleUsesAnyRuntimeCallNamed(module, reachability, &symbols.container_runtime_decls) or
        moduleUsesAnyCall(module, reachability, &symbols.runtime_support_symbols) or
        moduleUsesRuntimeBackedTypes(module, reachability))
    {
        deps.runtime = true;
    }
    if (moduleUsesAnyStdCallNamed(module, reachability, &package_manifest.std_prelude_print_decls)) {
        deps.std = true;
        deps.runtime = true;
    }
    applyStdModuleDeps(allocator, module, reachability, &deps);
    if (deps.std) deps.runtime = true;

    return deps;
}

fn moduleUsesRuntimeBackedTypes(module: lir.Module, reachability: ?Reachability) bool {
    for (module.functions, 0..) |function, index| {
        if (!functionReachable(reachability, index) or function.is_extern) continue;
        if (backendTypeNeedsRuntime(module, function.return_type)) return true;
        for (function.params) |param| {
            if (backendTypeNeedsRuntime(module, param.ty)) return true;
        }
        for (function.locals) |local| {
            if (backendTypeNeedsRuntime(module, local.ty)) return true;
        }
        for (function.blocks) |block| {
            for (block.instructions) |inst| {
                if (inst.ty) |ty| {
                    if (backendTypeNeedsRuntime(module, ty)) return true;
                }
                if (instDataNeedsRuntime(inst.data)) return true;
            }
        }
    }
    return false;
}

fn backendTypeNeedsRuntime(module: lir.Module, ty: lir.TypeId) bool {
    return descriptorHelperNeedsGeneration(module, ty);
}

fn instDataNeedsRuntime(data: lir.InstData) bool {
    return switch (data) {
        .dense_new,
        .dense_copy,
        .dense_len,
        .dense_clear,
        .dense_reserve,
        .dense_data,
        .dense_at,
        .dense_push,
        .dense_push_move,
        .dense_pop,
        .dense_drop,
        .sparse_new,
        .sparse_copy,
        .sparse_drop,
        .sparse_len,
        .sparse_capacity,
        .sparse_clear,
        .sparse_indices,
        .sparse_contains_index,
        .sparse_payload_ptr,
        .sparse_get,
        .sparse_set,
        .sparse_set_move,
        .sparse_insert,
        .sparse_insert_move,
        .sparse_take,
        .sequence_cmp,
        .sparse_cmp,
        => true,
        else => false,
    };
}

fn applyStdModuleDeps(allocator: std.mem.Allocator, module: lir.Module, reachability: ?Reachability, deps: *ArtifactDeps) void {
    for (module.functions, 0..) |function, index| {
        if (!functionReachable(reachability, index)) continue;
        for (function.blocks) |block| {
            for (block.instructions) |inst| {
                switch (inst.data) {
                    .call => |call| if (findFunctionByCallName(module, call.name)) |callee| {
                        if (package_manifest.stdArtifactForModuleName(allocator, callee.module_name) catch null) |artifact| {
                            switch (artifact) {
                                .std => deps.std = true,
                            }
                        }
                    },
                    else => {},
                }
            }
        }
    }
}

fn findFunctionByCallName(module: lir.Module, call_name: []const u8) ?lir.Function {
    const index = findFunctionIndexByCallName(module, call_name) orelse return null;
    return module.functions[index];
}

fn findFunctionIndexByCallName(module: lir.Module, call_name: []const u8) ?usize {
    for (module.functions, 0..) |function, index| {
        const emitted_name = function.abi_name orelse function.name;
        if (std.mem.eql(u8, emitted_name, call_name)) return index;
    }
    return null;
}

pub fn moduleUsesRuntime(allocator: std.mem.Allocator, module: lir.Module) bool {
    return moduleArtifactDeps(allocator, module).any();
}

const descriptor_names = @import("../lower/descriptor_names.zig");

pub const descriptorGlobalName = descriptor_names.descriptorGlobalName;
pub const descriptorCopyName = descriptor_names.descriptorCopyName;
pub const descriptorDropName = descriptor_names.descriptorDropName;
pub const descriptorNeedsGeneration = descriptor_names.descriptorNeedsGeneration;
pub const descriptorHelperNeedsGeneration = descriptor_names.descriptorHelperNeedsGeneration;

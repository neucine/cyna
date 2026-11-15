const std = @import("std");
const sir = @import("../sema/sir.zig");
const identity = @import("../sema/identity.zig");

pub const Error = error{InvalidIdentity} || std.mem.Allocator.Error;

pub const Indexes = struct {
    function_by_id: std.AutoHashMapUnmanaged(identity.DeclId, usize) = .empty,
    global_by_id: std.AutoHashMapUnmanaged(identity.DeclId, usize) = .empty,
    enum_by_id: std.AutoHashMapUnmanaged(identity.DeclId, usize) = .empty,
    union_by_id: std.AutoHashMapUnmanaged(identity.DeclId, usize) = .empty,
    struct_by_id: std.AutoHashMapUnmanaged(identity.DeclId, usize) = .empty,

    pub fn deinit(self: *Indexes, allocator: std.mem.Allocator) void {
        self.function_by_id.deinit(allocator);
        self.global_by_id.deinit(allocator);
        self.enum_by_id.deinit(allocator);
        self.union_by_id.deinit(allocator);
        self.struct_by_id.deinit(allocator);
    }

    pub fn buildDeclarations(self: *Indexes, allocator: std.mem.Allocator, module: sir.Module) Error!void {
        for (module.functions, 0..) |function_decl, index| {
            try put(&self.function_by_id, allocator, function_decl.decl_id orelse return error.InvalidIdentity, index);
        }
        for (module.enums, 0..) |decl, index| {
            try put(&self.enum_by_id, allocator, decl.decl_id orelse return error.InvalidIdentity, index);
        }
        for (module.unions, 0..) |decl, index| {
            try put(&self.union_by_id, allocator, decl.decl_id orelse return error.InvalidIdentity, index);
        }
        for (module.structs, 0..) |decl, index| {
            try put(&self.struct_by_id, allocator, decl.decl_id orelse return error.InvalidIdentity, index);
        }
    }

    pub fn registerGlobal(self: *Indexes, allocator: std.mem.Allocator, id: identity.DeclId, index: usize) Error!void {
        try put(&self.global_by_id, allocator, id, index);
    }

    pub fn function(self: *const Indexes, module: sir.Module, id: identity.DeclId) Error!sir.Function {
        return module.functions[self.function_by_id.get(id) orelse return error.InvalidIdentity];
    }

    pub fn enumDecl(self: *const Indexes, module: sir.Module, id: identity.DeclId) Error!sir.EnumDecl {
        return module.enums[self.enum_by_id.get(id) orelse return error.InvalidIdentity];
    }

    pub fn unionDecl(self: *const Indexes, module: sir.Module, id: identity.DeclId) Error!sir.UnionDecl {
        return module.unions[self.union_by_id.get(id) orelse return error.InvalidIdentity];
    }

    pub fn structDecl(self: *const Indexes, module: sir.Module, id: identity.DeclId) Error!sir.StructDecl {
        return module.structs[self.struct_by_id.get(id) orelse return error.InvalidIdentity];
    }

    pub fn globalIndex(self: *const Indexes, id: identity.DeclId) Error!usize {
        return self.global_by_id.get(id) orelse error.InvalidIdentity;
    }

    pub fn enumIndex(self: *const Indexes, id: identity.DeclId) Error!usize {
        return self.enum_by_id.get(id) orelse error.InvalidIdentity;
    }

    pub fn unionIndex(self: *const Indexes, id: identity.DeclId) Error!usize {
        return self.union_by_id.get(id) orelse error.InvalidIdentity;
    }

    fn put(
        map: *std.AutoHashMapUnmanaged(identity.DeclId, usize),
        allocator: std.mem.Allocator,
        id: identity.DeclId,
        index: usize,
    ) Error!void {
        const result = try map.getOrPut(allocator, id);
        if (result.found_existing) return error.InvalidIdentity;
        result.value_ptr.* = index;
    }
};

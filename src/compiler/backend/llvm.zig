const std = @import("std");
const emitter = @import("llvm/emitter.zig");
const backend_support = @import("support.zig");
const lir = @import("../lower/lir.zig");

pub const Error = emitter.Error;
pub const emitModule = emitter.emitModule;
pub const emitModuleWithOptions = emitter.emitModuleWithOptions;
pub const EmitOptions = emitter.EmitOptions;
pub const ArtifactDeps = backend_support.ArtifactDeps;

pub fn moduleArtifactDeps(allocator: std.mem.Allocator, module: lir.Module) ArtifactDeps {
    return backend_support.moduleArtifactDeps(allocator, module);
}

pub fn moduleArtifactDepsForObject(allocator: std.mem.Allocator, module: lir.Module) ArtifactDeps {
    const reachability = backend_support.allFunctionsReachable(allocator, module) catch return .{};
    defer reachability.deinit(allocator);
    return backend_support.moduleArtifactDepsWithReachability(allocator, module, reachability);
}

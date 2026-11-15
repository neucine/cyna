const allocators = @import("allocators/suite.zig");
const exec_refs_projection = @import("../exec/refs_projection.zig");
const exec_storage = @import("../exec/storage.zig");
const pointers = @import("pointers/suite.zig");
const projections = @import("projections/suite.zig");
const resource_handoff = @import("resource_handoff/suite.zig");
const sema_alignment = @import("../sema/alignment.zig");
const sema_callable_boundary = @import("../sema/callable_boundary.zig");
const sema_refs_projection = @import("../sema/refs_projection.zig");
const sema_storage = @import("../sema/storage.zig");

test {
    _ = allocators;
    _ = exec_refs_projection;
    _ = exec_storage;
    _ = pointers;
    _ = projections;
    _ = resource_handoff;
    _ = sema_alignment;
    _ = sema_callable_boundary;
    _ = sema_refs_projection;
    _ = sema_storage;
}

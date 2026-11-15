const pointers = @import("ownership/pointers/suite.zig");
const projections = @import("ownership/projections/suite.zig");
const resource_handoff = @import("ownership/resource_handoff/suite.zig");

test {
    _ = pointers;
    _ = projections;
    _ = resource_handoff;
}

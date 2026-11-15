const allocators = @import("ownership/allocators/suite.zig");
const declarations = @import("language/declarations/suite.zig");
const generics = @import("language/generics/suite.zig");
const integer_behavior = @import("language/integer_behavior/suite.zig");
const pointers = @import("ownership/pointers/suite.zig");
const projections = @import("ownership/projections/suite.zig");
const resource_handoff = @import("ownership/resource_handoff/suite.zig");
const unions_result = @import("language/unions_result/suite.zig");

test {
    _ = allocators;
    _ = declarations;
    _ = generics;
    _ = integer_behavior;
    _ = pointers;
    _ = projections;
    _ = resource_handoff;
    _ = unions_result;
}

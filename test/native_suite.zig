const allocators = @import("ownership/allocators/suite.zig");
const declarations = @import("language/declarations/suite.zig");
const exec_suite = @import("exec/suite.zig");
const generics = @import("language/generics/suite.zig");
const integer_behavior = @import("language/integer_behavior/suite.zig");
const pointers = @import("ownership/pointers/suite.zig");
const projections = @import("ownership/projections/suite.zig");
const resource_handoff = @import("ownership/resource_handoff/suite.zig");
const std_json = @import("std/json/suite.zig");
const unions_result = @import("language/unions_result/suite.zig");

test {
    _ = allocators;
    _ = declarations;
    _ = exec_suite;
    _ = generics;
    _ = integer_behavior;
    _ = pointers;
    _ = projections;
    _ = resource_handoff;
    _ = std_json;
    _ = unions_result;
}

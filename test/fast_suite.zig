const diagnostics = @import("diagnostics/suite.zig");
const inline_assembly = @import("language/inline_assembly/suite.zig");
const lower_suite = @import("lower/suite.zig");
const surface_suite = @import("surface/suite.zig");

test {
    _ = diagnostics;
    _ = inline_assembly;
    _ = lower_suite;
    _ = surface_suite;
}

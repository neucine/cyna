const abi_suite = @import("abi/suite.zig");
const infra_suite = @import("infra/suite.zig");
const language_suite = @import("language/suite.zig");
const ownership_suite = @import("ownership/suite.zig");
const tooling_suite = @import("tooling/suite.zig");

test {
    _ = abi_suite;
    _ = infra_suite;
    _ = language_suite;
    _ = ownership_suite;
    _ = tooling_suite;
}

const cli_suite = @import("../cli/suite.zig");
const lsp_diagnostics = @import("lsp/diagnostics.zig");

test {
    _ = @import("fmt/format.zig");
    _ = cli_suite;
    _ = lsp_diagnostics;
}

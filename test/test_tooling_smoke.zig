const help_smoke = @import("cli/help_smoke.zig");
const lsp_diagnostics = @import("tooling/lsp/diagnostics.zig");

test {
    _ = help_smoke;
    _ = lsp_diagnostics;
}

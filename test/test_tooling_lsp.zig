const lsp_diagnostics = @import("tooling/lsp/diagnostics.zig");
const lsp_presentation = @import("tooling/lsp/presentation.zig");
const lsp_session = @import("tooling/lsp/session.zig");

test {
    _ = lsp_diagnostics;
    _ = lsp_presentation;
    _ = lsp_session;
}

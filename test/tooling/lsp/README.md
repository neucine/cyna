# LSP

Coverage target: diagnostics, symbols, document lifecycle, imports, partial
source, and editor-facing responses.

Sufficient coverage includes valid and invalid source, incremental changes,
multi-module workspaces, and stable JSON-RPC behavior.

Structured diagnostics cover the callable direct-argument refactor boundary
and preserve the supported direct-call/explicit-context alternatives in the
editor-facing message.

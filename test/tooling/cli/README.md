# CLI

Coverage target: command dispatch, common flags, exit codes, stdout/stderr,
and invalid command usage.

Sufficient coverage includes success and failure cases for public commands and
stable diagnostics for common mistakes.

The focused `cyna check` suite covers the callable direct-argument refactor
boundary and verifies that the CLI names both the call-local lifetime rule and
the supported direct-call/explicit-context alternatives.

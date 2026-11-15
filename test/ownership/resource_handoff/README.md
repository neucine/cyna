# Resource Handoff

Coverage target: moves, transfers, function arguments, returns, reassignment,
and invalid reuse of moved resources.

Sufficient coverage includes accepted safe handoffs, rejected invalid handoffs,
diagnostics, generic/container cases, and runtime cleanup checks.

Current files:

- `optional_take.zig`: carried-forward optional `take` execution tests
- `suite.zig`: feature suite import root

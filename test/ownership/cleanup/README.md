# Cleanup

Coverage target: defer, drop, early return, error propagation, panic paths,
scope exit, and exactly-once destruction.

Sufficient coverage includes normal scope exit, branch and loop exits, early
returns, `try`, resource payloads, leak checks, and no double-drop regressions.

Current focused LIR coverage includes optional resource payload handoff without
callee cleanup and call-local resource capture cleanup for non-escaping
callables.

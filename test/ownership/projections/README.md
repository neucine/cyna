# Projections

Coverage target: ownership through fields, indexes, union payloads, optional
places, slices, and nested aggregate projections.

Sufficient coverage includes read, borrow, mutation, detach or rejection, shape
tests for place representation, and native behavior for representative cases.

Current files:

- `exec.zig`: carried-forward projection execution tests
- `suite.zig`: feature suite import root
- `COVERAGE.md`: coverage bar and known gaps

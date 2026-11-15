# Allocators

Coverage target: allocator contexts, scoped allocators, region behavior,
container allocation, and rejection of escaping scoped resources.

Sufficient coverage includes parse/sema acceptance, unsafe escape diagnostics,
native allocation behavior, and cleanup/leak checks.

Current files:

- `exec.zig`: carried-forward native allocator-context behavior tests
- `suite.zig`: feature suite import root

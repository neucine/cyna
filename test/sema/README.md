# Semantic Test Ownership

The files in this directory are source-level semantic integration tests. They
must exercise the compiler through the public lex, parse, load, and
`buildSir`/`buildSirWithOptions` entry points exposed by `test/helpers.zig`.
They must not depend on private `sema.zig` declarations.

The integration inventory is registered through the test-root
`test/test_sema.zig` artifact. This keeps shared helpers within the Zig module
boundary and allows the complete semantic suite to run concurrently with the
other full-gate artifacts.

Tests that directly exercise private semantic lattices, canonical-type
construction, provenance operations, or boundary-analysis helpers remain
colocated with `src/compiler/sema/sema.zig`. Those are unit tests of private
implementation contracts, not semantic phase integration tests.

`test-fast` retains compiler module unit tests and focused surface coverage,
but does not aggregate this full integration inventory. The required semantic
ownership gate is:

- `zig build test-fast`
- `zig build test`
- `zig build test-tooling-lsp`

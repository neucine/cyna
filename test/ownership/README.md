# Ownership Tests

This domain protects Cyna's safety and resource model. Tests here should cover
acceptance, rejection, diagnostics, lowering shape, runtime cleanup, joins, and
interprocedural summaries where relevant.

Ownership coverage is organized into these subareas:

- `pointers/`
- `borrows/`
- `projections/`
- `resource_handoff/`
- `copy_and_assignment/`
- `cleanup/`
- `allocators/`
- `invalidation/`
- `interprocedural/`

The executable suite also imports the compiler-wide characterization tests
that exercise the same semantic model across layers:

- `allocators/exec.zig`
- `pointers/exec.zig`
- `projections/exec.zig`
- `resource_handoff/optional_take.zig`
- `../exec/refs_projection.zig`: mutable/read-only aliases, carrier copying,
  call/return/storage, and receiver behavior
- `../sema/refs_projection.zig`: alias capability and mutation diagnostics
- `../sema/alignment.zig`: place and projection ownership analysis
- `../sema/callable_boundary.zig`: interprocedural ownership boundaries

This is deliberately a cross-layer suite: an ownership rule is protected by
semantic acceptance/rejection, structured diagnostics where relevant, lowered
shape checks elsewhere in `test/lower`, and native execution for
representative behavior. `suite.zig` is the executable inventory; this file is
not a list of future placeholders.

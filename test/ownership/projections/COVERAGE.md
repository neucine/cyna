# Projection Ownership Coverage

Spec target: `docs/SPEC.md` projection, borrow, mutation, and invalidation
rules, especially sections 16 and 17.

## Current Coverage

Carried-forward tests cover:

- resource field mutation through indexed container elements
- borrowed receiver calls through indexed field paths
- nested non-packed field aliases such as `&user.inner.age`
- packed-field alias rejection through nested paths
- ordinary projected-container aliases and explicit `view()` borrows
- field projection through read-only and writable protocol-index aliases
- focused root/projection/use characterization for local parameters, globals,
  raw dereferences, temporaries, and union payload aliases
- semantic and native coverage for projected global aliases and writable and
  read-only raw-pointee field aliases
- one lowering place-path interface shared by local field/index aliases and
  optional-place `take` paths
- returned slices derived from slice parameters and global storage
- rejection of returned slices derived from local and by-value parameter
  storage
- named nested field assignment capture for displaced resource and scalar
  values, mutable captured bindings, generic field origins, and duplicate-name
  rejection

## Sufficient Coverage Bar

- Semantics: projected resource access is accepted only when the ownership rule
  permits it.
- Execution: nested field/index projections read and mutate the intended place.
- Shape: lower/SIR/LIR tests preserve place paths without leaking path storage.
- Diagnostics: invalid projected detaches or escapes explain the ownership
  rule.

## Known Gaps

- Move more projection-heavy tests from `exec/refs_projection.zig` into this
  feature folder.
- Add more diagnostic tests for unsupported or unsafe projection detaches.
- Extend explicit shape tests when the compatibility SIR alias/take variants
  are removed in favor of the canonical place-path record.

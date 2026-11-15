# Declarations Coverage

Spec target: `docs/SPEC.md` sections 4, 4.1, 4.2, 4.3, and 4.4.

Related module visibility behavior also touches section 3.

## Current Coverage

Carried-forward tests cover:

- private imports rejected across files
- private struct fields rejected across files
- ambiguous selected imports rejected
- private globals rejected across files
- top-level global initialization and mutation
- imported public globals
- global struct, union, optional, fixed-array, and nested projection reads
- mutable global indexed and field mutation
- cross-file mutable global mutation
- non-escaping callable parameters with non-capturing, named, scalar-capturing,
  and resource-capturing direct arguments

## Sufficient Coverage Bar

- Surface: `const`, `var`, type definitions, visibility, and top-level
  declaration syntax parse or reject correctly.
- Semantics: visibility, top-level initialization policy, public/private
  access, and ambiguous imports are accepted/rejected correctly.
- Execution: global initialization, reads, projections, and mutation behave
  correctly at runtime.
- Diagnostics: invalid top-level initialization, private access, and ambiguous
  names report useful messages.
- Modules: multi-file declaration behavior is covered where visibility depends
  on import boundaries.

## Known Gaps

- Split module/import visibility tests into `language/modules/`.
- Split global execution behavior from semantic visibility failures.
- Add focused diagnostics for top-level initializer restrictions.
- Add coverage for type definitions and distinct aliases in this feature
  folder.
- Add target coverage only if global layout or initialization becomes
  target-sensitive.

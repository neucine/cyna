# Inline Assembly Coverage

Spec target: `docs/SPEC.md` section 24.1.

## Current Coverage

Carried-forward semantic tests cover:

- inline assembly requires `unchecked`
- undeclared placeholders are rejected
- unused inputs are rejected
- expression asm requires an output placeholder
- explicit output operands
- explicit inout operands
- tied input operands
- tied inputs require explicit output
- supported and unsupported register clobbers

## Known Gaps

- Add backend/target shape checks for emitted assembly constraints.
- Add target-specific register sets beyond the current AArch64-sensitive check.
- Add execution tests only when host-safe assembly snippets are available.

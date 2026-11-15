# Unions, Optionals, And Results Coverage

Spec target: `docs/SPEC.md` sections 9, 9.1, 9.2, 9.3, 9.4, and 10.

## Current Coverage

Carried-forward tests cover:

- raw C union field type requirements
- raw C union field reads inside `unchecked`
- union switch payload binding
- union payload projection
- union case constructor inference
- result case inference
- optional/result string payload inference
- optional and union `is` capture narrowing
- explicit optional absence propagation and rejection of `try` on `?T`
- runtime string payload behavior
- resource payload behavior
- union switch over payload and empty cases
- union-containing struct cleanup
- result switch over resource payloads
- `try` success and error paths
- leak-sensitive list/result/union payload cases

Negative cases currently live in the semantic negative collection:

- ambiguous union payload casts
- missing expected union case type
- non-exhaustive union switches
- projection of empty union cases
- invalid `is` capture placement

## Sufficient Coverage Bar

- Surface: union, optional, result, switch, projection, `is`, and `try` syntax
  parse or reject correctly.
- Semantics: exhaustiveness, payload availability, case inference, narrowing,
  projection, and `try` rules are accepted/rejected correctly.
- Execution: payload values, empty cases, switches, projections, `is` capture,
  and `try` produce correct runtime behavior.
- Ownership: resource payloads clean up exactly once and cannot escape through
  unsound projections or captures.
- Diagnostics: non-exhaustive switches, invalid projections, ambiguous casts,
  and invalid captures report useful messages.

## Known Gaps

- Split `exec.zig` into `surface.zig`, `sema.zig`, `diagnostics.zig`,
  `exec.zig`, and `ownership.zig`.
- Move unions/result negative cases from the broad negative table into this
  feature folder.
- Add focused diagnostic-substring tests for common union/result mistakes.
- Add target coverage only if representation, layout, or ABI rules become
  target-sensitive.
- Consider moving raw C union cases that are mainly ABI/layout checks into
  `abi/layout/` while keeping language-surface cases here.

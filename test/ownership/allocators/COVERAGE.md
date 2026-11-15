# Allocator Coverage

Spec target: `docs/SPEC.md` sections 18.3 and 19.

Related ownership model: `docs/SEMANTICS.md` storage, transfer, drop, and escape
rules.

## Current Coverage

Carried-forward execution tests cover:

- allocator context syntax executing as a scoped statement
- scoped allocator local temporary use
- scoped-owned storage with raw pointer local mutation under `unchecked`
- scalar copies out of scoped-owned aggregates
- nested container creation and copy
- non-capturing union and optional values leaving scoped blocks
- union projections from scoped-owned aggregates
- indexed and nested field-index projections
- helper-built projections
- raw pointer passthrough and local rebinding under `unchecked`
- runtime abort when an installed root allocator returns no storage

Negative scoped-allocator escape cases currently live in the broad ownership
negative table.

## Sufficient Coverage Bar

- Surface: allocator context forms parse and invalid forms reject.
- Semantics: scoped resources cannot escape, but copied plain values can.
- Execution: scoped allocator blocks run correctly and clean up resources.
- Ownership: projections, optionals, unions, containers, and raw pointers obey
  scoped lifetime rules.
- Diagnostics: escaping scoped resources report useful messages.

## Known Gaps

- Move scoped allocator negative cases out of the broad negative table into this
  feature folder.
- Add diagnostic-substring tests for escaping scoped resources.
- Split raw pointer `unchecked` cases into a separate file if the folder grows.
- Add explicit cleanup/leak assertions for representative scoped resources.
- Add a freestanding execution harness before characterizing missing-root
  allocator failure beyond the runtime contract.
- Add target coverage only if allocator/runtime behavior becomes
  target-sensitive.

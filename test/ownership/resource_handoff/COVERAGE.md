# Resource Handoff Coverage

Spec target: `docs/SPEC.md` section 17, especially `take`, assignment, copying,
and resource handoff.

## Current Coverage

Carried-forward optional `take` tests cover:

- dense-array optional index detaches
- resource optional index detaches
- `take` through ref parameters
- local and nested struct-field optional index detaches
- indexed field paths
- local optional binding clears to `none`
- optional field take clears to `none`
- non-detaching reads from optional indexes

## Sufficient Coverage Bar

- Semantics: valid handoffs compile and invalid moves/reuses are rejected.
- Execution: `take` clears the source place and returns the expected value.
- Ownership: resource payloads detach without leaks or double drops.
- Diagnostics: invalid handoff and unsupported take locations report useful
  messages.

## Known Gaps

- Move negative handoff cases from broad semantic tables into this folder.
- Add cleanup/leak assertions for representative resource `take` paths.
- Add shape tests for source-place clearing through nested projections.

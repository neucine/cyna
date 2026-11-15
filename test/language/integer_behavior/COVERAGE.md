# Integer Behavior Coverage

Spec target: `docs/SPEC.md` sections 20, 20.1, 20.1.1, and 20.1.2.

## Current Coverage

Carried-forward tests:

- uncontexted integer literals retaining values beyond `i32`
- uncontexted float literals retaining f64 precision
- checked integer narrowing
- fallible integer casts
- enum representation casts
- unusual-width integer casts
- integer/float casts
- C integer casts
- enum and flags casts
- optional payload casts
- union payload casts
- invalid cast runtime failures

## Sufficient Coverage Bar

- Surface: cast syntax and ambiguous forms parse or reject correctly.
- Semantics: valid conversions are accepted and invalid conversion forms are
  rejected with diagnostics.
- Execution: checked and fallible conversions produce correct runtime results.
- Diagnostics: invalid casts report useful user-facing messages where the
  failure is compile-time.
- Targets: `usize`, `isize`, C integer aliases, and unusual-width integers are
  checked on target-width-sensitive configurations.
- ABI: C integer conversions are covered where C boundary behavior depends on
  representation width.

## Known Gaps

- Split compile-time diagnostics from runtime failure cases.
- Add explicit surface tests for cast syntax where parser ambiguity exists.
- Add target-specific `usize`/`isize` cases under the target runner model.
- Continue moving overflow/arithmetic behavior that is not cast-specific into
  this feature folder.
- Batch pure native success cases after the feature structure is stable.

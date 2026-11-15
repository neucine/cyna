# Integer Behavior

Spec coverage target: sections 20, 20.1, 20.1.1, and 20.1.2 in
`docs/SPEC.md`.

This feature folder owns integer arithmetic, overflow behavior, checked casts,
bitcasts, unusual-width integer types, target-width `usize`/`isize` behavior,
and diagnostics for invalid conversions.

Current files:

- `casts.zig`: carried-forward native cast behavior tests
- `suite.zig`: feature suite import root
- `COVERAGE.md`: coverage bar and known gaps

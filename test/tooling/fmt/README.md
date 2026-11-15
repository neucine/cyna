# Format Command

Run `zig build test-tooling-fmt` for focused formatter and command coverage.
These tests also participate in `zig build test-tooling`.

Coverage includes deterministic formatting and idempotence, preservation of
comments/literals/escaped identifiers, safe construction-type normalization,
retention of constructors in other contexts, invalid source protection,
`--check` without writes, updating files, and recursive directory exclusions.
See `docs/BUILD.md` for the user-facing contract and current limitations.

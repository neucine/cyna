# Cyna 0.5.1 beta 1 release notes

This beta release repairs the language and native-compilation failures found
while porting Hao and compute-core to Cyna. It remains a prerelease so these
fixes can be exercised before the 0.5.1 stable release.

## Language and ownership

- Named unions accept contextual `none` cases in declarations, constructors,
  `is` tests, and switch labels.
- Struct fields can declare defaults, and omitted fields are initialized for
  plain, contextual, owned, and generic construction. Supplying the same field
  explicitly more than once is rejected.
- Borrowed field projections from owned temporaries now materialize and clean
  up their temporary place correctly.
- Indirect calls preserve owned arguments and close over their complete
  expression lifetime. This fixes non-deterministic `std.config` setting loads
  in native applications.

## Native compilation

- Indirect calls pass borrowed large aggregates by address at the LLVM ABI
  boundary.
- Imported C scalar results initialize failure-trace metadata before error
  cleanup, fixing typed filesystem failures through exported Cyna functions.
- Native object cache identities stream generated LLVM IR through SHA-256.
  Large test roots no longer fail with `StreamTooLong` when their LLVM module
  exceeds 128 MB.

## Release tooling

- Release preflights, site snapshots, and GitHub publishing accept semver
  prerelease versions such as `0.5.1-beta.1`.
- GitHub releases created for prerelease versions are marked as prereleases.

See [0.5.0 release notes](release-0.5.0.md) for the previous stable release and
[LANGUAGE_GAPS.md](language_gaps.md) for remaining investigations and
boundaries.

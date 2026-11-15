# Cyna 0.5.1 release notes

Cyna 0.5.1 promotes the 0.5.1 beta to a stable release. It includes the
language, ownership, and native compilation fixes described in the
[0.5.1 beta 1 notes](RELEASE_0_5_1_beta_1.md).

## Highlights

- Named unions accept contextual `none` in declarations, constructors, `is`
  tests, and switch labels.
- Struct field defaults apply when fields are omitted from plain, contextual,
  owned, and generic construction.
- Borrowed projections from owned temporaries and indirect calls preserve
  their required lifetimes and cleanup.
- Native compilation fixes the ABI handling of borrowed large aggregates and
  initializes failure trace metadata for imported C scalar results.
- Large native test roots stream LLVM IR into cache identities, avoiding the
  previous `StreamTooLong` limit.

## Release verification

The distribution release gate runs on the local macOS, Linux, and Windows
Buildkite agents. Each runner first checks pinned dependencies and tools,
reusing verified local caches. The release work then builds the binary and
packages the distribution on that platform. The platform scripts provide the
host-specific commands. The macOS release
bundle also records its LLVM runtime dependencies. Windows 0.5.1 verification
uses the pinned Windows inputs and uploads its zip distribution from the
Windows agent.

See [0.5.0 release notes](RELEASE_0_5_0.md) for the previous stable release
and [language gaps](LANGUAGE_GAPS.md) for remaining investigations.

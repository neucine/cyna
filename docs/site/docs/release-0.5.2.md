# Cyna 0.5.2 release notes

Cyna 0.5.2 adds a Windows x86-64 distribution alongside the macOS Apple Silicon
and Linux x86-64 archives. It also improves how release builds check and package
the compiler on each host.

## Windows distribution

The Windows ZIP contains `cyna.exe`, the tools it needs to compile native
programs, the bundled standard library, and target support files. Extract the
ZIP and run `bin\cyna.exe version` from the extracted directory. Add its `bin`
and `llvm\bin` directories to `PATH` when building programs.

The release check builds the ZIP on Windows, then uses the extracted package to
compile and run a small program and several examples.

## Other changes

- Release candidates are checked on macOS, Linux, and Windows before approval.
- macOS archive installation refreshes timestamps for verified cached archives,
  avoiding false stale archive errors during later builds.
- Final distribution jobs rebuild and smoke test their packages using the
  candidate's full test results from the same commit.

See [0.5.1 release notes](release-0.5.1.md) for the previous release.

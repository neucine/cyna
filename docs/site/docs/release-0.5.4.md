# Cyna 0.5.4 release notes

Cyna 0.5.4 fixes Windows GNU target selection, repairs compiler ownership and
import handling, and expands the standard library's string, crypto, and byte
I/O support.

## Toolchain fixes

- Windows projects can select `x86_64-pc-windows-gnu` explicitly. Both omitted
  targets and `target = "native"` select the GNU triple on Windows and Linux.
- The Windows compiler driver translates target names for its bundled GNU
  headers and runtime libraries. Release packaging uses the corrected driver
  source path.
- The PowerShell installer validates the manifest included in the Windows ZIP.
- Release packaging preserves the optimized compiler and runtime libraries
  across the compiler test suite.
- Explicit `target = "native"` builds on macOS retain the SDK flags used for
  C compilation and linking.

## Compiler fixes

- Dependency modules retain their identity across imports.
- Ownership and lowering fixes cover raw pointers, references, borrowed
  arrays, and projected union payloads.
- Named union payload projections track the lifetime of their owner.

## Standard library

- Added string operations, cryptographic helpers, and byte I/O APIs.
- Added streaming file I/O and portable hosted-library tests for Windows.
- Standard library guides now live with the bundled `std` package.

See [0.5.3 release notes](release-0.5.3.md) for the previous release.

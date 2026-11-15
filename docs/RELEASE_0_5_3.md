# Cyna 0.5.3 release notes

Cyna 0.5.3 repairs Windows native builds that use the standard library and C
libraries. It also makes the Windows distribution use the same GNU target for
generated code, its runtime archives, and the bundled compiler driver.

## Windows fixes

- File and path operations now work on Windows, including directory iteration.
- C calls pass strings and return results using the Windows x64 calling
  convention. This fixes crashes when reading files from Cyna code.
- LLVM helper functions can link across separately compiled Windows modules.
- The bundled tools are found by their `.exe` names, and release builds select
  the Windows GNU target explicitly.

See [0.5.2 release notes](RELEASE_0_5_2.md) for the previous release.

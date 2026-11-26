# Cyna 0.5.5 release notes

Cyna 0.5.5 adds named arguments and trailing parameter defaults, improves
Windows C interoperability, and fixes package builds that include C sources.

## Language and compiler

- Calls can use named arguments, and functions can give trailing parameters
  default values.
- Windows C callback adapters and small aggregate returns follow the Windows
  x64 ABI. The aggregate-return fix has cross-target coverage; native Windows
  runtime validation is still pending.
- Added regression coverage for an imported type with the same name as a
  local optional alias.

## Packages and standard library

- C sources in path dependencies are compiled with that package's include
  paths and compiler flags.
- `std.fs` uses `OpenMode` flags for `open`, with `open_read` and `open_write`
  as shorthands. Directory operations are named `mkdir`, `ls`, and `rmdir`.
- The JSON null case is named `null`.

See [0.5.4 release notes](RELEASE_0_5_4.md) for the previous release.

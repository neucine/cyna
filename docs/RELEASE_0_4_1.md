# Cyna 0.4.1 release notes

This update builds on 0.4.0's typed failure surface. It includes compiler
correctness repairs, faster verification of large modules, and a small set of
additive expression and control-flow forms.

## Compiler and runtime

- Repair checked-place lowering after indexing hooks, optional field
  assignments, owned returns from anonymous functions and test bodies, and
  shadowed local bindings.
- Avoid repeated whole-function scans during semantic finalization and SIR
  verification. This reduces the verification cost of large downstream roots.
- Drop unused sections from freestanding runtime artifacts.

## Source language

- Allow optional truth tests and same-name narrowing after early-return guards.
- Allow concise `catch` value arms and terminal concise `switch` arms.
- Add `unreachable;` for paths that cannot continue.
- Allow contextual enum case labels in `switch` arms.

## Documentation and tooling

The spec and quick reference now use checked import examples and clarify
projected bindings, alias writes, and string byte-view lifetimes. The gap ledger
distinguishes compiler defects from application ownership choices and proposed
standard-library conveniences. Release integration checks cover the Cyna skill,
VS Code extension, LSP, and formatter.

See [0.4.0 release notes](RELEASE_0_4_0.md) for the typed-failure migration.

# Cyna 0.5.0 release notes

This is the largest source-language expansion since typed failures. It adds
structural tuples, local `const` destructuring, projected indexed bindings, and
the stable hosted owned-input task API, alongside a broad set of compiler
correctness and verification-cost repairs.

## Source language

- Structural tuple types support `()`, `(T,)`, `(T, U)`, positional `.0`
  access, nested local `const` patterns, generic substitution and inference,
  cross-module calls, returns, and declarative globals.
- Local `const` destructuring supports struct shorthand and aliases, nested
  struct patterns, and positional indexed patterns. Omitted fields and elements
  remain with their owner.
- Projected bindings created from owned fields and indexed places stay valid
  through their last use, including tracked slice views and writable parameter
  aliases. Overlapping mutation, growth, and owned handoff are rejected while a
  projection is live.
- Plain `break;` exits the nearest `while` or `for`, including custom iterator
  loops, with exited-scope cleanup and ownership/borrow joins.
- Optional truth tests, `is none` early-return narrowing, and Boolean `is`
  tests compose with existing optional control flow.
- Generic call and `try` arguments propagate contextual types more reliably,
  including explicit generic calls and inferred bang returns.
- Contextual enum case labels resolve through transparent aliases.
- Static global dependency order is defined and enforced, and globals may copy
  mutable declared initial values.

## Concurrency

- Hosted owned-input `Task<R>`, `TaskGroup`, and `TaskContext` are stable on
  `aarch64-apple-darwin`.
- Task results preserve typed failure traces through join, ready polling, and
  nested propagation. Discarded results retire their trace.
- Owned storage transfers through task boundaries, including nested carriers,
  affine task handles in dense and sparse containers, and transferable named
  unions.
- Void task polling, cancellation, descendant work, and explicit group
  settlement follow the limits documented in `CONCURRENCY.md`.
- `std.thread` and `std.sync` continue to expose hosted thread, mutex,
  condition-variable, atomic, and synchronized collection APIs.

## Compiler correctness

- Struct, enum, and union lookups now use qualified nominal identities across
  literal layout, inherent methods, syntax hooks, protocol methods, borrow
  summaries, inline-test `TestError`, runtime descriptors, and declaration
  field parsing. Same-named private and imported declarations no longer
  collide.
- A nullable borrowed slice return now distinguishes `?[]T` from `[]?T`, so
  `none` is accepted as the absence value of an optional slice.
- `c_float` fixed-array literals lower as 32-bit floats instead of doubles.
- Nullable raw-pointer C ABI bridges, imported typed-failure trace ABI,
  implicit `void!E` success fallthrough, alias carriers through `catch` and
  success returns, checked bindings inside switch expressions, and borrowed
  `for`-loop element lifetimes are repaired.
- Path-dependency relative imports and qualified free-function lookup resolve
  from the dependency root, and native tests link C sources from imported
  standard modules.
- Comparison chains with a cast on the right are no longer parsed as generic
  arguments.

## Performance, diagnostics, and tooling

- Large generated modules use indexed verifier duplicate checks and a larger
  compiler main stack instead of repeated whole-function scans.
- Build and semantic phases expose more telemetry, and the release flow gates
  on Cava tests and classfiles.
- Build output shows progress and source diagnostics by default, and unhandled
  Cyna errors and compiler-internal failures retain stable diagnostic codes and
  traces.
- Hosted `std.math` adds width-explicit scalar `log2`, `sqrt`, `pow`, `round`,
  `exp2`, and `floor`, plus optional rounded f64-to-f32 conversion.
- Release tooling installs the verified compiler locally, syncs cyna.dev, and
  checks the Cyna skill, VS Code extension, LSP, and formatter.

## Upgrade notes

- Boolean negation is spelled `not`. Prefix `!` is no longer a negation
  operator.
- The Unicode scalar primitive is now `char`; the former `Rune` spelling is no
  longer accepted.
- Type aliases that shadow built-in types are rejected.
- Static globals must follow the documented dependency order.
- `?[]T` and `[]?T` now produce distinct types. Code that accidentally relied
  on the former parser conflation should declare the intended layer explicitly.

See [0.4.1 release notes](RELEASE_0_4_1.md) for the previous release and
[current status](STATUS.md) for known limitations and standard-library
boundaries.

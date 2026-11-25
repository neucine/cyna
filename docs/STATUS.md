# Cyna Implementation Status

This document tracks the current implemented surface at a high level.

`SPEC.md` defines general language rules and `CONCURRENCY.md` defines the
current concurrency contract. This file answers a narrower question: what is
real in the compiler and toolchain today?

## Current Feature Boundaries (2026-10-29)

This matrix distinguishes stable rules from accessible experiments and known
implementation gaps. Availability is not a claim of complete verification.

| Surface | Current boundary | Owning evidence / contract |
| --- | --- | --- |
| Syntax contracts | Indexing and iteration use validated inherent `@syntax.*` methods, alongside slice views and sequence factories. `Index`, `IndexSet`, and `Iterable` are no longer prelude protocols; `Eq`, `Hash`, and `Clone` are protocols. | SPEC §22.3; `test/sema/refs_projection.zig`; `test/exec/refs_projection.zig` |
| Function arguments | Direct Cyna calls accept trailing literal defaults and named arguments in any order. Supplied expressions evaluate in source order, then omitted defaults in parameter order; ownership follows the target parameter. Methods, function pointers, intrinsics, qualified protocol calls, and C ABI declarations stay positional and exact-arity. | SPEC §5.1; `test/language/functions/named_defaults.zig` |
| String scalar iteration | `string.bytes()` supports byte iteration; `string.chars()` yields Unicode scalar `char` values through a shared string iterator. | SPEC §14.11; `test/exec/strings.zig` |
| Cryptographic digests | `std.crypto` provides SHA-256, HMAC-SHA-256, and tag verification over byte slices. The package manifest lists macOS arm64, Linux x86-64, and Windows x86-64; native behavior is verified on macOS arm64. | `packages/std/src/std_crypto.cy`; `test/exec/crypto.zig` |
| Byte I/O | `std.io` provides core `Reader` and `Writer` protocols with bounded `read_to_end` and partial-write `write_all`. Hosted `std.fs` provides explicit-close `File` handles, non-owning standard streams, and scalar-status `exists` checks that avoid a Windows x64 C aggregate-return ABI mismatch. Process pipes remain future work. | `packages/std/src/std_io.cy`; `packages/std/src/std_fs.cy`; native execution tests |
| Generics and protocols | Monomorphized; explicit impl bodies; shallow associated types and qualified dispatch implemented. No runtime protocol values or specialization. | SPEC §22; `test/language/generics/exec.zig`; `test/sema/negative/generics_protocols.zig` |
| Generic composition | Definition-site lowering and checked method-use records govern declared protocol admission and inferred returns. Caller-bound forwarding, including `Clone`, is supported; ownership and operator requirements remain inferred. | N08 closure ledger in daydream; `test/language/generics/exec.zig`; `test/lower/phase_baseline.zig` |
| Low-level hosted threads | `std.thread` currently ships for `aarch64-apple-darwin`. `std.sync` ships for macOS arm64, Linux x86-64, and Windows x86-64. Windows x64 probes cover atomics, mutex/condvar, shared handles, and ARC. `spawn<T>` returns an owned `Thread`; join/detach return a `ThreadOutcome` and preserve the handle on terminal failure. No scoped borrowed workers. See `CONCURRENCY.md`. | `packages/std/cyna.toml`; `test/sema/concurrency.zig`; `test/runtime/thread_bridge_native.c` |
| Task APIs | Stable owned-input `TaskGroup`, `Task<R>`, and `TaskContext` are available in `std.thread` on `aarch64-apple-darwin`; result transfer, polling, cancellation, descendant work, and explicit group settlement follow the limits in `CONCURRENCY.md`. | `packages/std/cyna.toml`; `packages/std/src/std_thread.cy`; concurrency coverage ledger; normalization N07 |
| Hosted config and telemetry | `std.config` supplies explicit typed settings, environment loading, parsers, runtime updates, and startup freezing. `std.telemetry` supplies explicit backend callbacks for metrics, spans, and events with caller-propagated context. Telemetry is available on macOS arm64, Linux x86-64, and Windows x86-64; config currently targets macOS arm64 and Linux x86-64. | `packages/std/CONFIG_TELEMETRY.md`; `examples/config_settings.cy`; `examples/telemetry_backend.cy` |
| TaskGroup lifecycle | Terminal calls such as `finish` and `cancel_and_wait` implement a library/caller protocol; the compiler does not require a terminal call on every path. It checks owner availability, borrow lifetime, and thread-transfer safety. Deferred owned handoffs reserve their source until scope exit; some statically unreachable loop moves remain conservatively rejected. | SPEC §18.1; `test/sema/concurrency.zig`; N07 closure ledger in daydream |
| Projected owned fields and indexed elements | `const field = owner.owned_field` and `const item = entries[index]` are read-only projected bindings for live owned storage, including elements reached through tracked slice views and writable parameter aliases. They capture the selected element and reject overlapping mutation, growth, and owned handoff through the binding's last use, including defers. Owner drop and replacement are admitted afterward. Checked payloads and value-returning indexing hooks remain outside this rule. | SPEC §9; `test/sema/alignment.zig`; `test/ownership/projections/exec.zig` |
| Local `const` destructuring | Struct field shorthand and aliases, nested struct patterns, and positional indexed patterns lower through one initializer and checked projected leaves. Omitted fields and elements stay with the owner. Borrowed scalar fields work; owned resource leaves through reference parameter roots remain rejected. Dynamic index selectors, `var` patterns, union cases, and value-returning indexing hooks are outside the implemented form. | SPEC §4; `test/sema/alignment.zig`; `test/ownership/projections/exec.zig` |
| Tuples | Structural tuple types support `()`, `(T,)`, `(T, U)`, positional `.0` access, nested local `const` patterns, generic substitution and inference, cross-module calls, returns, and declarative globals. Native layout uses ordered aggregate fields. Resource elements use checked member transfers and owner-linked projections; moving, rebinding, or dropping an owner with a live projection is rejected. Tuple types are rejected at C ABI boundaries. | SPEC §7.1; `test/sema/alignment.zig`; `test/ownership/projections/exec.zig`; `test/language/generics/exec.zig` |
| Places and mutability | Global/raw projected aliases preserve existing capability; mutable access does not become nominal type mutability. | SPEC; `test/sema/place_matrix.zig`; place-audit supersession note |
| C ABI | Public result carriers rejected; explicit C-layout adapters supported. Trusted std runtime bridges have separate authority. | `test/sema/c_abi.zig`; `test/exec/c_abi.zig` |
| Error returns | Public `T!E` returns, ordinary `return`/`throw`, `try`, block `catch (code[, failure]) { ... }`, and single-expression `catch (code[, failure]) => expression` are implemented. `E` is an enum or closed union of enums. Explicit `result<T,E>`, `.ok/.err` result cases, result switches/patterns, and legacy catch forms are rejected. The catch-scoped failure view exposes bounded source locations and an owned message; code-only fallback preserves the typed code on trace exhaustion. When a hosted task entry returns `T!E`, its trace survives join, polling, and nested propagation; discarded task results retire it. | SPEC §10; `test/language/unions_result/exec.zig`; `test/exec/core.zig`; `test/sema/negative_cases.zig` |
| Failure trace targets | Hosted native execution has bounded trace storage and prints an unhandled `main` error's message, throw location, and retained propagation sites. Freestanding runtime context allocation currently returns no store, so it carries typed error codes with code-only diagnostics. The `aarch64`, `x86_64`, and `riscv64` freestanding target lane checks emitted LLVM and ABI calls; it does not execute those targets. | `test/targets/failure_trace.zig`; `src/runtime/failure_trace.c`; `test/runtime/failure_trace_native.c` |

## Implemented Core

- Plain `break;` exits the nearest `while` or `for`, including custom iterator
  loops, with exited-scope cleanup and ownership/borrow state joins. Labels and
  value-producing breaks are not implemented.
- `Clone` is a prelude protocol with `clone(self: &const Self): Self`. Builtin
  strings clone to independent backing, and dense storage clones when its
  elements are descriptor-copy-safe. Standard collections clone their elements;
  `Arc<T>.clone()` retains a shared claim. The old `copy` operator and
  `@syntax.copy` attribute are removed.
- `@syntax.slice_view` instance-method contracts: const/mutable direct slices
  for List and renamed generic/imported owners, native range bounds checks,
  ordinary borrow provenance, and semantics-preserving `cyna fmt` normalization
- Integer-key `@syntax.index` and `@syntax.index_set` accept integer expressions
  in index syntax with a checked conversion to the hook key type; `cyna fmt`
  removes a redundant direct cast when semantic analysis proves the hook call
- `@syntax.sequence_literal` factory contracts: contextual empty/populated
  `List<T>` literals and user-defined targets, generic inference, import-aware
  selection, explicit ambiguity, and ordinary owned-storage call lowering
- multi-file package loading with `cyna.toml`
- root-project imports with leading `.` and dependency-package imports by package name
- parser, sema, SIR, LIR, and LLVM-native backend pipeline
- SIR preserves resolved call module identity so lowering does not re-resolve
  same-named private declarations across modules
- structs, enums, unions, distinct aliases, generics, protocols, containers, pointers, slices, `T!E` error returns, and optionals
- `packed struct` layout, packed field reads/writes, packed/int and same-width int/float `as!` reinterpretation, and the current `*volatile packed struct` subset
- strict public `extern c` / `export c`; canonical `c struct`, `c enum`, and
  `c union`; raw `*const` / `*volatile` and nested pointer qualifiers; distinct
  borrowed `c_str` parameters with safe static-literal adaptation; and current
  header emission
- inline `test "name" { ... }` execution with builtin `assert(...)`
- native hosted and freestanding target selection through the current manifest subset
- compiler-owned package loading for bundled `std`
- resource-first thread-boundary checks for recognized `std.thread.spawn` /
  `embedded.task.spawn` boundary contracts; trusted compiler and
  standard-library declarations carry stricter explicit boundary authority
- request-owned structured diagnostics with stable codes, byte spans,
  secondary labels, notes, help, reserved conservative fix metadata,
  deterministic ordering, exact deduplication, cascade suppression, and
  bounded parser recovery
- source-aware human and compact CLI rendering plus multi-file LSP publication
  with UTF-16 coordinates and related declaration locations
- versioned `ast-summary-v1` declaration inspection through `--emit-ast`

## Current Tooling Shape

- `cyna build`
- `cyna run`
- `cyna test`
- `cyna check`
- `cyna fmt [paths...] [--check]` (formatting, conservative construction-type normalization, proven slice-view and index-key cast normalization, and exact contextual numeric-literal cast normalization; see `BUILD.md`)
- `cyna install`
- `cyna package`
- `cyna lsp`
- `cyna version`
- shell-based public distribution install via `https://cyna.dev/install.sh`

## Current Std / Runtime Shape

- `std` is loaded from the filesystem as a package
- the shipped `std` package lives under the installed distribution
- runtime remains the mandatory execution layer
- public docs describe one per-target `libcyna.a` plus one per-target `libcyna_std.a`
- hosted macOS `std.math` provides width-explicit scalar log2, natural log, exp, sqrt, pow,
  round, exp2, floor, and optional rounded f64-to-f32 conversion; see
  `packages/std/MATH.md` for floating-point edge behavior and portability
- a few compiler internals still retain transitional naming from the older std split, but the public model is already the single `std` package plus `libcyna_std.a`
- hosted `std.thread` exposes thread handles, generic `spawn<T>` for
  descriptor-backed transferable payloads, `ThreadId`, `thread.current_id()`,
  and `Thread.join()` / `Thread.detach()`
- `Thread` is an opaque hosted join/detach handle; `ThreadId` is a separate
  opaque identity value with equality, and raw storage fields are private
- hosted `std.thread` also has internal spawn bridges including `spawn_raw`,
  `spawn_boxed`, and `spawn_i32`; generic `spawn<T>` lowers through the boxed
  payload-copy ABI, which honors descriptor size and alignment
- `std.thread` join/detach bridge externs are private; user code uses `Thread`
  handle methods
- hosted `std.sync` exposes the initial shared handle, `Locked<T>` for
  descriptor-backed one-value synchronized resources, `ConcurrentList<T>` for
  synchronized list ownership, `ConcurrentSlotMap<T>` for synchronized slot-map insertion/lookup, mutex,
  condition variable, and i32/usize/bool atomic primitives with handle methods
  over the trusted runtime bridge, including blocking and non-blocking mutex
  acquisition
- `std.sync` bridge externs are private; user code uses namespace constructors
  plus handle methods
- `std.sync` primitives expose opaque hosted handles with private
  implementation-defined native/runtime storage, not portable identities
- recognized thread-boundary analysis treats `std.sync` handles marked
  `@concurrency.shareable` as transferable and shareable; arbitrary user extern
  calls remain rejected unless explicitly marked `@concurrency.trusted_extern`
- runtime string retain/release uses atomic refcounting, so immutable string
  backing can be safely shared across hosted concurrency boundaries
- core `std.json` provides strict RFC 8259 validation, owned parsing, ordered
  object/array access, exact number spelling, duplicate-key rejection, compact
  encoding, and two-space pretty encoding on all bundled core targets

## Recent Fixes and Current Gaps

### Recursive nominal type lowering (2026-10-25)

Nominal struct and union lowering previously cached a type only after lowering
all fields. A field that referred back to its enclosing nominal type therefore
re-entered lowering indefinitely and crashed native compilation. Lowering now
registers a placeholder type before visiting fields and completes it in place.
The focused LIR regression covers a self-referential struct, and `std.json`
uses the repaired path for recursively owned `Value` arrays and objects.

### Reported by Lightcept (2026-10-24, Cyna `1314430`, hosted native, macOS arm64)

These reports were reproduced on the stated baseline. The dense `push` and
failure-diagnostic repairs below are implemented. A bare
sequence literal in a `for` header still requires a target type.

- **`push` on dense storage did not grow (repaired).** `SPEC.md` §15.4 defines `[:]T` as
  dense owned storage with runtime capacity, and `src/runtime/runtime.c` already
  has `cyna_reserve_bytes` (`runtime.dense.grow`), but
  `emitDensePushMutation` in
  `src/compiler/backend/llvm/instruction_emission.zig` previously only wrote in
  place and called `cyna_assert_fail` when `init_len >= capacity`. A bare sequence literal
  gets a derived capacity (literal length rounded up to a power of two, minimum
  four), so an ordinary push past it aborts. Smallest repro:

  ```cyna
  fn main(): i32 {
      var rows: [:]i32 = [1, 2, 3, 4, 5];
      rows.push(6); rows.push(7); rows.push(8); // len 8, succeeds
      rows.push(9);                             // exits 101, no diagnostic
      return rows.len() as i32;
  }
  ```

  Measured boundary over literal lengths 1..16: abort at final length 5, 9, or 17
  depending on the rounded capacity. `rows.reserve(64)` and the `[: 16] [1, 2, 3]`
  capacity prefix both behaved as expected, so the growth path existed but was
  not used by push. The LLVM emitter now reserves for `len + 1` before writing,
  reloads the carrier after growth, and rejects length overflow. A native
  regression covers growth past literal capacity and a value read from the
  same dense storage at the next growth boundary.
- **Language-level failure diagnostics (repaired).** The
  baseline `cyna_runtime_language_fail` path suppressed the leak check and
  called `exit(101)` without output. Hosted assertion failures now report the
  assertion, indexed bounds checks report index and length or capacity, and
  capacity checks report the requested and available capacity before exit 101.
  Other legacy runtime checks emit a generic check-failure message. Freestanding
  targets use the installed runtime writer for a short category message.
- **`for` headers cannot take a bare sequence literal.** `for value in [1, 2, 3]`
  fails in `src/compiler/sema/sema.zig` with `cannot infer array literal type`
  because the iteration head has no expected type. The diagnostic now suggests
  an explicit target type or a typed binding. Binding the literal first
  (`var values: [:]i32 = [1, 2, 3];`) works. No implicit literal inference
  was added because the spec requires contextual typing.

- distribution publishing still needs the full supported target archive set for every release
- release-facing documentation and implementation naming still need periodic
  drift checks as the distribution model settles
- compile-time value generics use `const N: usize`; the old fixed-array shape
  generic parameter spelling is removed
- generic hosted thread spawn is descriptor-backed for internally transferable
  payloads; stable `Thread.join()` returns settlement or a recoverable handle,
  without a worker result. Stable hosted `Task<R>.join()` carries results
  within the owned-input task contract above
- `std.sync.Shared<T>` remains the internal handle wrapper behind higher-level
  synchronized resources; `std.sync.locked<T>(value)` provides the first
  higher-level protected-value wrapper; `std.sync.concurrent_list<T>()`
  provides the first synchronized container wrapper with direct push/len/clear
  and scoped access; `std.sync.concurrent_slot_map<T>()` provides synchronized
  insertion, contains, len, and scoped access; low-level pointer-backed and
  explicitly leaked-owned constructors remain available as bridge escape
  hatches, while richer removal/clear operations and concurrent maps remain
  future work
- freestanding concurrency remains gated until `embedded.task` or board/runtime
  mechanisms provide an implementation surface

## Near-Term Focus

- finish syncing distribution artifacts and manifests with the public install model
- continue tightening std wrappers so user code does not reach directly into runtime ABI hooks
- keep folding stable design decisions back into `SPEC.md`, `RUNTIME.md`, `BUILD.md`, and `TOOLCHAIN.md`
- storage foundation redesign complete: `[:]T` (dense) and `[;]T` (sparse) are
  the canonical owned-storage forms; `Array<T>` is removed
- keep language features frozen by default; retained limitations become
  separately reviewed proposals rather than incidental compiler changes
- treat the completed compiler and diagnostics audits as architectural
  guardrails, with regression gates required before further tooling work
- use the completed language-ergonomics decision audit to close specification
  ambiguity before considering new syntax or semantic convenience
- all three language-ergonomics batches are complete; advanced generics and
  result/scoped concurrency remain evidence-gated proposals, while canonical
  ABI keywords and their attribute equivalents now have a settled
  compatibility direction

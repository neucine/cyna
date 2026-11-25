# Runtime and standard library

Cyna programs use two layers. The mandatory runtime implements compiler-lowered
operations such as allocation, string storage, collection storage, and cleanup.
The bundled `std` package provides the source-level APIs. Ordinary programs
import `std` modules and let `cyna build` link the runtime; they do not call
compiler/runtime bridge symbols directly.

The public source-level API is listed in
[standard library and runtime API](STD_RUNTIME_API.md).

## What is linked

For each supported target, the installed distribution contains `libcyna.a`
for the runtime and `libcyna_std.a` for the standard library's native code.
The compiler selects the archives for the build target. You do not need to
list these archives in `cyna.toml` or pass them as extra linker inputs.

The runtime also supplies target startup support where required. A build
fails with a target-support diagnostic if its required archives are missing.
See [toolchain](TOOLCHAIN.md) for the installed layout and available targets.

## The `std` package

The bundled package includes memory and allocation APIs, collections, I/O,
paths, filesystem and process operations, time, and hosted concurrency APIs.
The prelude supplies common language-facing types. Hosted modules that require
OS services are unavailable to freestanding targets; the compiler checks
availability when resolving imports. [Concurrency](CONCURRENCY.md) describes
thread, synchronization, and task behavior.

`std` is shipped with the compiler distribution, so a normal project does not
need a separate dependency declaration or download for it. Other package
dependencies belong in `cyna.toml`; see [build](BUILD.md).

## Values and cleanup

The runtime performs cleanup according to the value's type and the compiler's
ownership decisions. Plain values copy without tracked cleanup. Shared values
preserve another claim or backing and release it according to the type's
contract. Owned values hand off cleanup responsibility, making the source
unavailable. `drop` and `defer` end responsibilities at explicit points. A
`.clone()` call creates another value according to its `Clone` implementation.

For example, ordinary assignment of `string` may share immutable backing;
`string.clone()` creates independent backing. Collection clones follow their
element contracts, while `Arc<T>.clone()` retains another shared claim. See
[terminology](GLOSSARY.md) for the names and [spec](SPEC.md) for the rules.

## C interop boundary

Public `extern c` and `export c` declarations use C-compatible types. The
runtime's private representations do not make `string`, Cyna storage, or
`result` valid public C ABI types. Use the C ABI rules in the
[spec](SPEC.md) and `cyna build --emit-c-header` when exposing Cyna declarations
to C code.

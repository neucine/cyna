# Standard library and runtime API

This reference covers the APIs you can call from ordinary Cyna code: language
builtins, prelude types, and the bundled `std` modules. Each module has its own
page so you can browse it from the sidebar and keep the surrounding concepts
on screen.

Only public APIs are documented here. Compiler internals, runtime bridge
symbols, private helper functions, private struct fields, and implementation-only
handle types are excluded.

Use the table below when you know the job but not the module. If you already
know the module, open it from the API Reference sidebar.

## Choose an API

| I want to... | Page |
| --- | --- |
| Print, assert, inspect strings, or use prelude containers | [Language and prelude](std-prelude.md) |
| Change the allocator used by the standard library | [std.alloc](std-alloc.md) |
| Write test assertions | [std.testing](std-testing.md) |
| Search, fill, or copy bytes | [std.mem](std-mem.md) |
| Read or write a byte stream | [std.io](std-io.md) |
| Parse or write JSON | [std.json](std-json.md) |
| Open files, inspect directories, or use standard streams | [std.fs](std-fs.md) |
| Join or inspect paths | [std.path](std-path.md) |
| Read environment variables or run a child process | [std.process](std-process.md) |
| Measure elapsed time or sleep | [std.time](std-time.md) |
| Use scalar math functions | [std.math](std-math.md) |
| Compute a digest or HMAC | [std.crypto](std-crypto.md) |
| Load typed configuration | [std.config](std-config.md) |
| Emit metrics or trace spans | [std.telemetry](std-telemetry.md) |
| Run work on another thread | [std.thread](std-thread.md) |
| Protect shared state or use atomics | [std.sync](std-sync.md) |
| Share an owned value between threads | [std.own](std-own.md) |
| Understand the public runtime surface | [Runtime API](std-runtime-boundary.md) |

## How to read the API

Every module page uses the same sections:

| Section | What it lists |
| --- | --- |
| `Types` | Key structs, enums, protocols, and public fields. |
| `Static functions` | Functions called through a module or type, such as `std.fs.read_file` or `AtomicI32.init`. |
| `Instance methods` | Functions called on a value, such as `file.close()` or `task.join()`. |
| `Errors` | Public error types and status values. |
| `Example` | A short working example of the module. |

Cyna API names follow the same rules as the rest of the language:

- `T!E` means the call can return a value of type `T` or fail with error `E`.
- `?T` means an optional value; `none` is the empty case.
- `&T` is a borrow, `[]T` is a slice, and `[]const T` is a read-only slice.
- A value described as owned must be closed, consumed, or dropped according to
  its type.
- A borrowed value remains valid only while its source is alive.

Import either the module or the names you need:

```cyna
import std.fs;
import { join } from std.path;
```

The bundled package manifest decides which modules exist for a target. If a
module is unavailable, the compiler rejects the import before linking.

## Module availability

The installed package manifest is authoritative. These are the bundled target
groups at the current release:

| Modules | Available on |
| --- | --- |
| `std.prelude`, `std.alloc`, `std.io`, `std.mem`, `std.json` | macOS arm64, Linux x86-64, Windows x86-64, and bundled freestanding targets |
| `std.testing` | The same targets except Windows x86-64 |
| `std.crypto`, `std.fs`, `std.path`, `std.time`, `std.math`, `std.process`, `std.telemetry`, `std.sync` | macOS arm64, Linux x86-64, and Windows x86-64 |
| `std.config`, `std.thread`, `std.own` | macOS arm64 and Linux x86-64 |

The separate `embedded` package provides freestanding architecture and HAL
helpers such as `embedded.arch`, `embedded.hal`, and chip-specific device
definitions. It is not part of the hosted `std` package.

A module can be implemented on a target and still be omitted from a particular
distribution. Check the manifest installed with your compiler when portability
matters.

## Related references

- [Runtime and standard library](runtime.md) explains the two-layer linking
  model and C interop.
- [Language spec](spec.md) defines imports, ownership, and ABI rules.
- [Concurrency](concurrency.md) defines thread, task, and synchronization
  execution boundaries.

# Runtime API

Cyna has no public runtime module and no public `builtin_*` module. The runtime
is an implementation detail behind the language and the bundled `std` package.

Use these public surfaces instead:

| You need to... | Public API |
| --- | --- |
| Print or assert from language code | [Language and prelude](PRELUDE.md) |
| Install an allocator | [std.alloc](ALLOC.md) |
| Redirect printed output | [std.io](IO.md) |
| Work with files and standard streams | [std.fs](FS.md) |
| Work with threads and shared state | [std.thread](THREAD.md), [std.sync](SYNC.md), [std.own](OWN.md) |
| Expose Cyna declarations to C | `cyna build --emit-c-header` |

Runtime bridge symbols are internal. They are not stable user API and should
not be declared with `extern c` in application code. The C header emitted by
the compiler contains only the declarations you explicitly expose.

For the linking model and C interop, see
[Runtime and standard library](../RUNTIME.md) and the
[language spec](../SPEC.md).

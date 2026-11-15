# C Interop

Coverage target: `extern c`, `export c`, C-to-Cyna calls, Cyna-to-C calls,
extra C sources, and libc/toolchain integration.

Sufficient coverage includes both call directions, primitive and aggregate
arguments, return values, diagnostics, and target-sensitive ABI cases.

Current semantic/backend coverage also proves that canonical keyword ABI
declarations and accepted `@abi`/`@link.*` equivalents share one symbol and
backend contract.

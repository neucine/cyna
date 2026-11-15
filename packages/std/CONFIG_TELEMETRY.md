# Hosted configuration and telemetry

`std.config` and `std.telemetry` are available on `aarch64-apple-darwin`.
They provide the primitives needed by a Cyna port of Affon's compute adapter.

## Configuration

Create a `Setting<T>` for each field in an application-owned config struct.
`startup`, `runtime`, and `readonly` take an environment name, a typed default,
and a parser function. Call `load_env()` for each field during initialization;
it returns whether the variable was present and keeps the previous value if
parsing fails. Call `freeze()` on startup fields after initialization. Runtime
fields remain writable through `set()`. `readonly` fields reject `set()` and
`load_env()`; use them for values supplied directly by the application.

The library has parsers for Boolean values (`true/false`, `yes/no`, `1/0`,
`on/off`), positive `usize`, and nonempty strings. Applications supply parsers
for enums and domain values. The parser receives an owned `string`; returned
strings may keep it. `Setting<T>.get()` returns the current value.

See [`examples/config_settings.cy`](../../examples/config_settings.cy) for an
executable example. The application must call `load_env()` explicitly for each
field; Cyna does not reflect over struct fields or generate path-based setters.

## Telemetry

`Backend` is an explicit set of callbacks for metric additions and sets, span
starts, events, and span ends. Pass a backend to code that emits evidence.
`disabled()` supplies callbacks that discard it. A `Scope` holds the backend
and the host's `SpanHandle`; use `child()` to propagate the parent context.
The host supplies trace and span IDs. Each callback receives a monotonic
timestamp. If the hosted clock fails, the timestamp is zero.
Use `bool_attribute`, `int_attribute`, `float_attribute`, and
`text_attribute` to construct event and span attributes.

Callback arguments, including attribute slices, are borrowed for the duration
of the call. A host that retains records must copy names and attributes.
Callbacks must be safe for the threads from which the application calls them.
The library does not install process-wide state or implicit thread context;
pass `TraceContext` explicitly between spans and workers.

See [`examples/telemetry_backend.cy`](../../examples/telemetry_backend.cy) for
an executable collector. The current ID representation uses 64-bit integers,
so hosts adapting a wider trace identity must maintain that mapping.

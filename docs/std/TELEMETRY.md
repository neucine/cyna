# std.telemetry

`std.telemetry` emits metrics, events, and spans through a host-provided
backend. The application chooses the collector by supplying callbacks.

Available on macOS arm64, Linux x86-64, and Windows x86-64.

```cyna
import { Attribute, Backend, Metric, Scope, disabled } from std.telemetry;
```

## Types

### `Metric`

| Field | Type | Meaning |
| --- | --- | --- |
| `group` | `string` | Metric group. |
| `name` | `string` | Metric name. |
| `kind` | `MetricKind` | `counter` or `gauge`. |
| `unit` | `MetricUnit` | `count`, `bytes`, or `nanoseconds`. |

`MetricKind` has the cases `counter` and `gauge`. `MetricUnit` has the cases
`count`, `bytes`, and `nanoseconds`.

### `Attribute`

| Field | Type | Meaning |
| --- | --- | --- |
| `key` | `string` | Attribute name. |
| `kind` | `AttributeKind` | `boolean`, `integer`, `float`, or `text`. |
| `boolean` | `bool` | Boolean payload. |
| `integer` | `i64` | Integer payload. |
| `float` | `f64` | Float payload. |
| `text` | `string` | Text payload. |

Use the attribute constructors instead of filling all payload fields.

`AttributeKind` has the cases `boolean`, `integer`, `float`, and `text`.

### `TraceContext`

| Field | Type | Meaning |
| --- | --- | --- |
| `trace_id` | `u64` | Trace identity. |
| `span_id` | `u64` | Parent span identity. |
| `sampled` | `bool` | Whether the trace is sampled. |

### `SpanHandle`

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | `usize` | Host span identity. |
| `context` | `TraceContext` | Context for child work. |

### `Backend` and `Scope`

`Backend` holds the callback set and its context value. `Scope` represents an
open span and carries the backend that will receive its records.

`SpanKind` has the cases `internal`, `server`, `client`, `producer`, and
`consumer`. `SpanStatus` has the cases `unset`, `ok`, and `err`.

## Static functions

Call these through the module or an imported name.

| Function | Signature | Description |
| --- | --- | --- |
| `bool_attribute` | `fn bool_attribute(key: string, value: bool): Attribute` | Creates a boolean attribute. |
| `int_attribute` | `fn int_attribute(key: string, value: i64): Attribute` | Creates an integer attribute. |
| `float_attribute` | `fn float_attribute(key: string, value: f64): Attribute` | Creates a float attribute. |
| `text_attribute` | `fn text_attribute(key: string, value: string): Attribute` | Creates a text attribute. |
| `root_context` | `fn root_context(): TraceContext` | Creates a root trace context. |
| `disabled` | `fn disabled(): Backend` | Creates a backend that drops every record. |

## Instance methods

### `Backend`

| Method | Signature | Description |
| --- | --- | --- |
| `add` | `fn add(self: Backend, metric: Metric, delta: i64): void` | Adds to a counter or gauge. |
| `set` | `fn set(self: Backend, metric: Metric, value: i64): void` | Sets a gauge value. |
| `start_span` | `fn start_span(self: Backend, parent: TraceContext, name: string, kind: SpanKind, attributes: []const Attribute): Scope` | Starts a span. |

### `Scope`

| Method | Signature | Description |
| --- | --- | --- |
| `event` | `fn event(self: Scope, name: string, attributes: []const Attribute): void` | Records an event in the span. |
| `child` | `fn child(self: Scope, name: string, kind: SpanKind, attributes: []const Attribute): Scope` | Starts a child span. |
| `end` | `fn end(self: Scope, status: SpanStatus): void` | Ends the span. |

## Example

```cyna
import std.telemetry;
import { int_attribute, root_context } from std.telemetry;

fn record_work(backend: telemetry.Backend): void {
    const attributes: [1]telemetry.Attribute = [int_attribute("items", 3)];
    const scope = backend.start_span(
        root_context(),
        "work",
        telemetry.SpanKind.internal,
        attributes[..]
    );
    scope.event("started", attributes[..]);
    scope.end(telemetry.SpanStatus.ok);
}
```

Use `disabled()` when telemetry is not configured. Attribute slices are borrowed
only for the duration of a callback. Pass `TraceContext` explicitly; there is no
implicit thread-local context.

# std.time

`std.time` provides clocks, sleeping, and elapsed-time measurements.

Available on macOS arm64, Linux x86-64, and Windows x86-64.

```cyna
import { TimeError, elapsed_ms, monotonic_ns, sleep_ms } from std.time;
```

## Static functions

Call these through the module or an imported name.

| Function | Signature | Description |
| --- | --- | --- |
| `now_ns` | `fn now_ns(): i64 ! TimeError` | Reads wall-clock time in nanoseconds. |
| `monotonic_ns` | `fn monotonic_ns(): i64 ! TimeError` | Reads a monotonic clock in nanoseconds. |
| `sleep_ns` | `fn sleep_ns(duration: i64): void ! TimeError` | Sleeps for a nanosecond duration. |
| `sleep_ms` | `fn sleep_ms(duration: i64): void ! TimeError` | Sleeps for a millisecond duration. |
| `elapsed_ns` | `fn elapsed_ns(start: i64): i64 ! TimeError` | Measures from a monotonic timestamp. |
| `elapsed_ms` | `fn elapsed_ms(start: i64): i64 ! TimeError` | Measures from a monotonic timestamp in milliseconds. |
| `ns_to_ms` | `fn ns_to_ms(ns: i64): i64` | Converts nanoseconds to milliseconds. |
| `ms_to_ns` | `fn ms_to_ns(ms: i64): i64 ! TimeError` | Converts milliseconds to nanoseconds. |

Use `monotonic_ns` for elapsed time; wall-clock time can move backward.
`ms_to_ns` rejects negative durations and values that would overflow.

## Errors

| Error | Meaning |
| --- | --- |
| `TimeError.unavailable` | The clock or sleep operation is unavailable. |
| `TimeError.overflow` | A unit conversion would overflow. |
| `TimeError.invalid_duration` | The duration is negative or invalid. |

## Example

```cyna
import { TimeError, elapsed_ms, monotonic_ns, sleep_ms } from std.time;

fn pause(): i64 ! TimeError {
    const start = try monotonic_ns();
    try sleep_ms(10);
    return try elapsed_ms(start);
}
```

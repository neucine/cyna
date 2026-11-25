# std.math

`std.math` provides scalar math functions that follow the host C math library.
Each name states its operand and result precision.

Available on macOS arm64, Linux x86-64, and Windows x86-64.

```cyna
import { log2_f64, pow_f64, sqrt_f64, to_f32_rounded } from std.math;
```

## Static functions

Call these through the module or an imported name.

| Function | Signature | Description |
| --- | --- | --- |
| `log2_f64` | `fn log2_f64(value: f64): f64` | Base-2 logarithm. |
| `log_f64` | `fn log_f64(value: f64): f64` | Natural logarithm. |
| `exp_f64` | `fn exp_f64(value: f64): f64` | Exponential. |
| `sqrt_f64` | `fn sqrt_f64(value: f64): f64` | Square root. |
| `pow_f64` | `fn pow_f64(base: f64, exponent: f64): f64` | Raises `base` to `exponent`. |
| `round_f64` | `fn round_f64(value: f64): f64` | Rounds to the nearest integer value. |
| `log2_f32` | `fn log2_f32(value: f32): f32` | Base-2 logarithm in `f32`. |
| `exp2_f32` | `fn exp2_f32(value: f32): f32` | Base-2 exponential in `f32`. |
| `pow_f32` | `fn pow_f32(base: f32, exponent: f32): f32` | Raises `base` to `exponent` in `f32`. |
| `floor_f32` | `fn floor_f32(value: f32): f32` | Rounds down in `f32`. |
| `to_f32_rounded` | `fn to_f32_rounded(value: f64): ?f32` | Converts to `f32`, or returns `none` when the value is not representable. |

Domain and overflow behavior matches the host math library. For example,
`sqrt_f64(-1.0)` produces NaN and `log_f64(0.0)` produces negative infinity.
These functions return floats rather than Cyna errors.

## Example

```cyna
import { sqrt_f64 } from std.math;

fn distance(a: f64, b: f64): f64 {
    const delta = a - b;
    return sqrt_f64(delta * delta);
}
```

Use `to_f32_rounded` for intentional lossy conversion. The `as f32` operator is
an exact checked conversion.

# `std.math` (hosted macOS)

`import std.math;` exposes `log2_f64`, `log_f64`, `exp_f64`, `sqrt_f64`, `pow_f64`,
`round_f64`, `log2_f32`, `exp2_f32`, `pow_f32`, `floor_f32`, and
`to_f32_rounded`. Names state the input and output width. The functions
call the corresponding C `<math.h>` functions through the std C companion.
No C ABI types appear in the public signatures.

The transcendental functions follow the host C math library: `log2(0)` and
`log(0)` are negative infinity, `log2` or `log` of a negative finite value and `sqrt` of a
negative finite value produce NaN, and `pow` follows the host library's
domain and pole rules (including negative bases with nonintegral exponents).
`exp` of positive infinity is positive infinity, `exp` of negative infinity
is positive zero, and finite overflow produces positive infinity.
NaN and infinities propagate or produce the C library's specified special
results. Exact last bits and exception flags can vary by host math library.
`floor_f32` rounds toward negative infinity; `round_f64` rounds halfway
cases away from zero. Both preserve a zero result's sign, as do the C math
functions where the C standard specifies it. These functions return a float;
they do not turn domain or overflow conditions into Cyna errors.

`to_f32_rounded(value)` returns `?f32`. It returns `none` for NaN,
infinity, and values with magnitude greater than the largest finite `f32`.
Otherwise the C cast rounds to nearest, ties to even under the default host
floating point rounding mode, including subnormal results and signed zero.
The caller must retain the default rounding mode; changing the process
rounding mode changes the result. A finite value below half the least
subnormal may round to signed zero. Cyna's `as f32` remains an exact checked
conversion; use this named function when lossy rounding is intended.

The module currently targets `aarch64-apple-darwin`, matching the hosted
std package. Its C implementation links against the platform math library
through the std archive. Other platforms need an explicitly supported
target and appropriate math library linkage before import is available.

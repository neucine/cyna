// Hosted scalar math. Each name states its operand and result precision.
extern c("cyna_std_math_log2_f64") fn native_log2_f64(value: c_double): c_double;
extern c("cyna_std_math_log_f64") fn native_log_f64(value: c_double): c_double;
extern c("cyna_std_math_exp_f64") fn native_exp_f64(value: c_double): c_double;
extern c("cyna_std_math_sqrt_f64") fn native_sqrt_f64(value: c_double): c_double;
extern c("cyna_std_math_pow_f64_bits") fn native_pow_f64_bits(base: c_double, exponent: c_double): u64;
extern c("cyna_std_math_round_f64") fn native_round_f64(value: c_double): c_double;
extern c("cyna_std_math_log2_f32") fn native_log2_f32(value: c_float): c_float;
extern c("cyna_std_math_exp2_f32") fn native_exp2_f32(value: c_float): c_float;
extern c("cyna_std_math_pow_f32") fn native_pow_f32(base: c_float, exponent: c_float): c_float;
extern c("cyna_std_math_floor_f32") fn native_floor_f32(value: c_float): c_float;
extern c("cyna_std_math_to_f32") fn native_to_f32(value: c_double, output: *c_float): c_int;

pub fn log2_f64(value: f64): f64 {
    return native_log2_f64(value as c_double) as f64;
}
// Host libm handles nonfinite inputs and domains: log(0) is -infinity,
// log(negative) is NaN, and exp overflows to positive infinity.
pub fn log_f64(value: f64): f64 {
    return native_log_f64(value as c_double) as f64;
}
pub fn exp_f64(value: f64): f64 {
    return native_exp_f64(value as c_double) as f64;
}
pub fn sqrt_f64(value: f64): f64 {
    return native_sqrt_f64(value as c_double) as f64;
}
pub fn pow_f64(base: f64, exponent: f64): f64 {
    return native_pow_f64_bits(base as c_double, exponent as c_double) as! f64;
}
pub fn round_f64(value: f64): f64 {
    return native_round_f64(value as c_double) as f64;
}
pub fn log2_f32(value: f32): f32 {
    return native_log2_f32(value as c_float) as f32;
}
pub fn exp2_f32(value: f32): f32 {
    return native_exp2_f32(value as c_float) as f32;
}
pub fn pow_f32(base: f32, exponent: f32): f32 {
    return native_pow_f32(base as c_float, exponent as c_float) as f32;
}
pub fn floor_f32(value: f32): f32 {
    return native_floor_f32(value as c_float) as f32;
}

// Returns none for nonfinite input or a magnitude above the largest finite f32.
pub fn to_f32_rounded(value: f64): ?f32 {
    const zero: c_float = 0.0;
    var output: [1]c_float = [zero];
    if native_to_f32(value as c_double, output[0..].ptr as! *c_float) == 0 {
        return none;
    }
    return output[0] as f32;
}

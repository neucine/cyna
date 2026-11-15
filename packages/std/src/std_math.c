#include <math.h>
#include <float.h>

double cyna_std_math_log2_f64(double value) { return log2(value); }
double cyna_std_math_log_f64(double value) { return log(value); }
double cyna_std_math_exp_f64(double value) { return exp(value); }
double cyna_std_math_sqrt_f64(double value) { return sqrt(value); }
double cyna_std_math_pow_f64(double base, double exponent) { return pow(base, exponent); }
double cyna_std_math_round_f64(double value) { return round(value); }
float cyna_std_math_log2_f32(float value) { return log2f(value); }
float cyna_std_math_exp2_f32(float value) { return exp2f(value); }
float cyna_std_math_pow_f32(float base, float exponent) { return powf(base, exponent); }
float cyna_std_math_floor_f32(float value) { return floorf(value); }

int cyna_std_math_to_f32(double value, float *output) {
    if (!output || !isfinite(value) || value > FLT_MAX || value < -FLT_MAX) return 0;
    // The host's default IEEE rounding mode rounds to nearest, ties to even.
    *output = (float)value;
    return 1;
}

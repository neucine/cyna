pub const maximum_channel_magnitude: f64 = 65536.0;
const half: f64 = 0.5;
const small: f32 = 1.0;

fn main(): i32 {
    if maximum_channel_magnitude * half == 32768.0 {
        return 42;
    }
    return 0;
}

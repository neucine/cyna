pub enum TimeError: i32 {
    unavailable = 0,
    overflow,
    invalid_duration,
}

pub extern c fn now_ns(): i64 ! TimeError;
pub extern c fn monotonic_ns(): i64 ! TimeError;
pub extern c fn sleep_ns(duration: i64): void ! TimeError;

pub fn ns_to_ms(ns: i64): i64 {
    return ns / 1000000;
}

pub fn ms_to_ns(ms: i64): i64 ! TimeError {
    if ms < 0 {
        throw TimeError.invalid_duration;
    }
    if ms > 9223372036854 {
        throw TimeError.overflow;
    }
    return ms * 1000000;
}

pub fn sleep_ms(duration: i64): void ! TimeError {
    const ns = try ms_to_ns(duration);
    try sleep_ns(ns);
    return;
}

pub fn elapsed_ns(start: i64): i64 ! TimeError {
    const now = try monotonic_ns();
    return now - start;
}

pub fn elapsed_ms(start: i64): i64 ! TimeError {
    const elapsed = try elapsed_ns(start);
    return ns_to_ms(elapsed);
}

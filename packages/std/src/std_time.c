#include <stdint.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <errno.h>
#include <time.h>
#endif

typedef enum {
    CYNA_TIME_UNAVAILABLE = 0,
    CYNA_TIME_OVERFLOW = 1,
    CYNA_TIME_INVALID_DURATION = 2,
} CynaTimeError;

typedef struct {
    uint8_t is_ok;
    int64_t ok;
    int32_t err;
} CynaResultI64TimeError;

typedef struct {
    uint8_t is_ok;
    uint8_t ok;
    int32_t err;
} CynaResultVoidTimeError;

static CynaResultI64TimeError cyna_std_time_result_i64_ok(int64_t value) {
    return (CynaResultI64TimeError){
        .is_ok = 0,
        .ok = value,
        .err = 0,
    };
}

static CynaResultI64TimeError cyna_std_time_result_i64_err(CynaTimeError err) {
    return (CynaResultI64TimeError){
        .is_ok = 1,
        .ok = 0,
        .err = err,
    };
}

static CynaResultVoidTimeError cyna_std_time_result_void_ok(void) {
    return (CynaResultVoidTimeError){
        .is_ok = 0,
        .ok = 0,
        .err = 0,
    };
}

static CynaResultVoidTimeError cyna_std_time_result_void_err(CynaTimeError err) {
    return (CynaResultVoidTimeError){
        .is_ok = 1,
        .ok = 0,
        .err = err,
    };
}

CynaResultI64TimeError cyna_std_time_now_ns(void) {
#ifdef _WIN32
    FILETIME file_time;
    GetSystemTimePreciseAsFileTime(&file_time);
    const uint64_t ticks = ((uint64_t)file_time.dwHighDateTime << 32) | file_time.dwLowDateTime;
    const uint64_t unix_epoch_ticks = 116444736000000000ULL;
    if (ticks < unix_epoch_ticks) {
        return cyna_std_time_result_i64_err(CYNA_TIME_UNAVAILABLE);
    }
    const uint64_t hundreds_of_ns = ticks - unix_epoch_ticks;
    if (hundreds_of_ns > (uint64_t)INT64_MAX / 100ULL) {
        return cyna_std_time_result_i64_err(CYNA_TIME_OVERFLOW);
    }
    return cyna_std_time_result_i64_ok((int64_t)(hundreds_of_ns * 100ULL));
#else
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) {
        (void)errno;
        return cyna_std_time_result_i64_err(CYNA_TIME_UNAVAILABLE);
    }
    if (ts.tv_sec > (INT64_MAX - ts.tv_nsec) / 1000000000LL) {
        return cyna_std_time_result_i64_err(CYNA_TIME_OVERFLOW);
    }
    return cyna_std_time_result_i64_ok((int64_t)ts.tv_sec * 1000000000LL + (int64_t)ts.tv_nsec);
#endif
}

CynaResultI64TimeError cyna_std_time_monotonic_ns(void) {
#ifdef _WIN32
    LARGE_INTEGER count;
    LARGE_INTEGER frequency;
    if (!QueryPerformanceCounter(&count) || !QueryPerformanceFrequency(&frequency) || frequency.QuadPart <= 0) {
        return cyna_std_time_result_i64_err(CYNA_TIME_UNAVAILABLE);
    }
    const int64_t seconds = count.QuadPart / frequency.QuadPart;
    const int64_t remainder = count.QuadPart % frequency.QuadPart;
    if (seconds > INT64_MAX / 1000000000LL) {
        return cyna_std_time_result_i64_err(CYNA_TIME_OVERFLOW);
    }
    return cyna_std_time_result_i64_ok(
        seconds * 1000000000LL + (remainder * 1000000000LL) / frequency.QuadPart);
#else
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        (void)errno;
        return cyna_std_time_result_i64_err(CYNA_TIME_UNAVAILABLE);
    }
    if (ts.tv_sec > (INT64_MAX - ts.tv_nsec) / 1000000000LL) {
        return cyna_std_time_result_i64_err(CYNA_TIME_OVERFLOW);
    }
    return cyna_std_time_result_i64_ok((int64_t)ts.tv_sec * 1000000000LL + (int64_t)ts.tv_nsec);
#endif
}

CynaResultVoidTimeError cyna_std_time_sleep_ns(int64_t duration) {
    if (duration < 0) {
        return cyna_std_time_result_void_err(CYNA_TIME_INVALID_DURATION);
    }

#ifdef _WIN32
    while (duration > 0) {
        int64_t milliseconds = duration / 1000000LL;
        if (milliseconds == 0) milliseconds = 1;
        if (milliseconds > (int64_t)MAXDWORD) milliseconds = (int64_t)MAXDWORD;
        Sleep((DWORD)milliseconds);
        duration -= milliseconds * 1000000LL;
    }
    return cyna_std_time_result_void_ok();
#else
    struct timespec requested = {
        .tv_sec = (time_t)(duration / 1000000000LL),
        .tv_nsec = (long)(duration % 1000000000LL),
    };
    if ((int64_t)requested.tv_sec != duration / 1000000000LL) {
        return cyna_std_time_result_void_err(CYNA_TIME_OVERFLOW);
    }

    while (nanosleep(&requested, &requested) != 0) {
        if (errno != EINTR) {
            return cyna_std_time_result_void_err(CYNA_TIME_UNAVAILABLE);
        }
    }
    return cyna_std_time_result_void_ok();
#endif
}

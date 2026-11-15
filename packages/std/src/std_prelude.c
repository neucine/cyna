#include "../../../src/runtime/cyna.h"

#ifdef CYNA_FREESTANDING

void cyna_runtime_abort(void);
void cyna_runtime_writer_write(const char *ptr, int64_t len);

static void cyna_std_prelude_abort(void) {
    cyna_runtime_abort();
}

static void cyna_std_prelude_writer_write_unsigned(uint64_t value) {
    char buf[32];
    int index = (int)sizeof(buf);
    do {
        buf[index - 1] = (char)('0' + (value % 10u));
        value /= 10u;
        index -= 1;
    } while (value != 0);
    cyna_runtime_writer_write(buf + index, (int64_t)(sizeof(buf) - (size_t)index));
}

static void cyna_std_prelude_writer_write_signed(int64_t value) {
    uint64_t magnitude;
    if (value < 0) {
        cyna_runtime_writer_write("-", 1);
        magnitude = (uint64_t)(-(value + 1)) + 1u;
    } else {
        magnitude = (uint64_t)value;
    }
    cyna_std_prelude_writer_write_unsigned(magnitude);
}

#else
#include <stddef.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

void cyna_runtime_writer_write(const char *ptr, int64_t len);

static void cyna_std_prelude_abort(void) {
    abort();
}

static void cyna_std_prelude_writer_printf(const char *format, ...) {
    va_list args;
    va_start(args, format);

    char stack_buf[256];
    va_list count_args;
    va_copy(count_args, args);
    int count = vsnprintf(stack_buf, sizeof(stack_buf), format, count_args);
    va_end(count_args);
    if (count < 0) {
        va_end(args);
        cyna_std_prelude_abort();
    }

    if ((size_t)count < sizeof(stack_buf)) {
        cyna_runtime_writer_write(stack_buf, (int64_t)count);
        va_end(args);
        return;
    }

    size_t heap_len = (size_t)count + 1;
    char *heap_buf = (char *)cyna_runtime_tracked_alloc_site(heap_len, __FILE__, __LINE__, "std.prelude.print.heap");
    if (heap_buf == NULL) {
        cyna_runtime_writer_write(stack_buf, (int64_t)(sizeof(stack_buf) - 1));
        va_end(args);
        return;
    }
    int heap_count = vsnprintf(heap_buf, heap_len, format, args);
    va_end(args);
    if (heap_count < 0) {
        cyna_runtime_tracked_free(heap_buf);
        cyna_std_prelude_abort();
    }
    cyna_runtime_writer_write(heap_buf, (int64_t)heap_count);
    cyna_runtime_tracked_free(heap_buf);
}

#endif

void cyna_std_prelude_print_string(CynaString value) {
    cyna_runtime_writer_write(value.ptr, cyna_string_logical_len(value));
}

void cyna_std_prelude_print_int(int64_t value, _Bool is_signed) {
#ifdef CYNA_FREESTANDING
    if (is_signed) {
        cyna_std_prelude_writer_write_signed(value);
        return;
    }
    cyna_std_prelude_writer_write_unsigned((uint64_t)value);
#else
    if (is_signed) {
        cyna_std_prelude_writer_printf("%lld", (long long)value);
        return;
    }
    cyna_std_prelude_writer_printf("%llu", (unsigned long long)(uint64_t)value);
#endif
}

void cyna_std_prelude_print_bool(_Bool value) {
    cyna_runtime_writer_write(value ? "true" : "false", value ? 4 : 5);
}

void cyna_std_prelude_print_newline(void) {
    cyna_runtime_writer_write("\n", 1);
}

void cyna_std_prelude_panic(CynaString message) {
    cyna_runtime_writer_write("panic: ", 7);
    cyna_runtime_writer_write(message.ptr, cyna_string_logical_len(message));
    cyna_runtime_writer_write("\n", 1);
    cyna_runtime_language_fail();
}

#include "cyna.h"

#ifdef CYNA_FREESTANDING
void *memcpy(void *dst, const void *src, size_t len) {
    unsigned char *out = (unsigned char *)dst;
    const unsigned char *in = (const unsigned char *)src;
    size_t i;
    for (i = 0; i < len; i += 1) out[i] = in[i];
    return dst;
}

void *memmove(void *dst, const void *src, size_t len) {
    unsigned char *out = (unsigned char *)dst;
    const unsigned char *in = (const unsigned char *)src;
    if (out == in || len == 0) return dst;
    if (out < in) {
        size_t i;
        for (i = 0; i < len; i += 1) out[i] = in[i];
    } else {
        size_t i = len;
        while (i != 0) {
            i -= 1;
            out[i] = in[i];
        }
    }
    return dst;
}

int memcmp(const void *lhs, const void *rhs, size_t len) {
    const unsigned char *a = (const unsigned char *)lhs;
    const unsigned char *b = (const unsigned char *)rhs;
    size_t i;
    for (i = 0; i < len; i += 1) {
        if (a[i] != b[i]) return (int)a[i] - (int)b[i];
    }
    return 0;
}

void *memset(void *dst, int value, size_t len) {
    unsigned char *out = (unsigned char *)dst;
    unsigned char byte = (unsigned char)value;
    size_t i;
    for (i = 0; i < len; i += 1) out[i] = byte;
    return dst;
}
#endif

#ifndef CYNA_H
#define CYNA_H

#ifdef CYNA_FREESTANDING
typedef __SIZE_TYPE__ size_t;
typedef __INT32_TYPE__ int32_t;
typedef __INT64_TYPE__ int64_t;
typedef __UINT8_TYPE__ uint8_t;
typedef __UINT32_TYPE__ uint32_t;
typedef __UINT64_TYPE__ uint64_t;
typedef __INTPTR_TYPE__ intptr_t;
typedef __UINTPTR_TYPE__ uintptr_t;
#ifndef NULL
#define NULL ((void *)0)
#endif
#define offsetof(type, member) __builtin_offsetof(type, member)
#else
#include <stddef.h>
#include <stdint.h>
#endif

/*
 * ABI definitions
 *
 * These declarations define the public C ABI surface shared by compiler-
 * generated export headers and runtime-facing interop code.
 */

typedef struct CynaAbiString {
    const char *ptr;
    int64_t len;
} CynaAbiString;

typedef struct CynaStringShared {
    intptr_t refcount;
    int64_t len;
    char bytes[];
} CynaStringShared;

typedef struct CynaAbiDense {
    const struct CynaTypeDesc *elem_desc;
    int64_t len;
    int64_t cap;
    unsigned char *data;
} CynaAbiDense;

typedef struct CynaAbiSparse {
    const struct CynaTypeDesc *elem_desc;
    int64_t len;
    int64_t cap;
    unsigned char *occupied;
    unsigned char *data;
} CynaAbiSparse;

typedef struct {
    uint8_t is_some;
    int64_t value;
} CynaOptionalI64;

typedef struct CynaTypeDesc CynaTypeDesc;

typedef void (*CynaCopyFn)(void *dst, const void *src, const CynaTypeDesc *desc);
typedef void (*CynaDropFn)(void *value, const CynaTypeDesc *desc);
typedef uint8_t (*CynaEqFn)(const void *lhs, const void *rhs, const CynaTypeDesc *desc);
typedef uint64_t (*CynaHashFn)(const void *value, const CynaTypeDesc *desc);
typedef void (*CynaWriterWriteFn)(const char *ptr, int64_t len, void *ctx);
typedef void *(*CynaAllocatorAllocFn)(void *ctx, size_t size);
typedef void *(*CynaAllocatorReallocFn)(void *ctx, void *ptr, size_t size);
typedef void (*CynaAllocatorFreeFn)(void *ctx, void *ptr);

struct CynaTypeDesc {
    int64_t size;
    int64_t align;
    uint32_t flags;
    CynaCopyFn copy;
    CynaDropFn drop;
    CynaEqFn eq;
    CynaHashFn hash;
    const void *extra;
};

typedef struct {
    void *ctx;
    CynaAllocatorAllocFn alloc;
    CynaAllocatorReallocFn realloc;
    CynaAllocatorFreeFn free;
} CynaAllocator;

typedef CynaAbiString CynaString;
typedef CynaAbiDense CynaDense;
typedef CynaAbiSparse CynaSparse;

typedef struct {
    unsigned char *ptr;
    int64_t len;
} CynaBytes;

extern const CynaTypeDesc cyna_desc_u8;
extern const CynaTypeDesc cyna_desc_i32;
extern const CynaTypeDesc cyna_desc_i64;
extern const CynaTypeDesc cyna_desc_f32;
extern const CynaTypeDesc cyna_desc_f64;
extern const CynaTypeDesc cyna_desc_bool;
extern const CynaTypeDesc cyna_desc_string;

static inline uint64_t cyna_string_owned_bit_u64(void) {
    return ((uint64_t)1) << 63;
}

static inline int64_t cyna_string_logical_len(CynaString value) {
    return (int64_t)(((uint64_t)value.len) & ~cyna_string_owned_bit_u64());
}

static inline int cyna_string_is_owned(CynaString value) {
    return ((((uint64_t)value.len) & cyna_string_owned_bit_u64()) != 0) ? 1 : 0;
}

static inline CynaString cyna_string_make_static(const char *ptr, int64_t len) {
    return (CynaString){ .ptr = ptr, .len = len };
}

static inline CynaString cyna_string_make_owned(const char *ptr, int64_t len) {
    return (CynaString){ .ptr = ptr, .len = (int64_t)(((uint64_t)len) | cyna_string_owned_bit_u64()) };
}

static inline CynaStringShared *cyna_string_shared_from_ptr(const char *ptr) {
    return (CynaStringShared *)((unsigned char *)ptr - offsetof(CynaStringShared, bytes));
}

static inline void cyna_string_shared_ref_init(CynaStringShared *shared) {
#ifdef CYNA_FREESTANDING
    shared->refcount = 1;
#else
    __atomic_store_n(&shared->refcount, (intptr_t)1, __ATOMIC_RELAXED);
#endif
}

static inline void cyna_string_shared_retain(CynaStringShared *shared) {
#ifdef CYNA_FREESTANDING
    shared->refcount += 1;
#else
    (void)__atomic_add_fetch(&shared->refcount, (intptr_t)1, __ATOMIC_RELAXED);
#endif
}

static inline int cyna_string_shared_release(CynaStringShared *shared) {
#ifdef CYNA_FREESTANDING
    return --shared->refcount == 0 ? 1 : 0;
#else
    return __atomic_sub_fetch(&shared->refcount, (intptr_t)1, __ATOMIC_ACQ_REL) == 0 ? 1 : 0;
#endif
}

/*
 * Runtime declarations
 *
 * These declarations are runtime services, not part of the minimal exported
 * function signature surface. C code only needs these when it directly uses
 * runtime allocation, ownership, or writer hooks.
 */

void cyna_runtime_install_root_allocator(CynaAllocator allocator);
void cyna_runtime_init_bump_root_allocator(void *start, size_t size);
void cyna_runtime_clear_root_allocator(void);
uint8_t cyna_runtime_has_root_allocator(void);
void cyna_std_io_install_writer(CynaWriterWriteFn write_fn, void *ctx);
void cyna_std_io_clear_writer(void);
void cyna_runtime_language_fail(void);
void cyna_runtime_assertion_fail(void);
void cyna_runtime_bounds_fail(int64_t index, int64_t length);
void cyna_runtime_capacity_fail(int64_t requested, int64_t capacity);
void cyna_runtime_writer_write(const char *ptr, int64_t len);
void cyna_runtime_assert_no_leaks(void);
void *cyna_runtime_tracked_alloc(size_t size);
void *cyna_runtime_tracked_realloc(void *ptr, size_t size);
void *cyna_runtime_tracked_alloc_site(size_t size, const char *site_file, int64_t site_line, const char *site_kind);
void *cyna_runtime_tracked_realloc_site(void *ptr, size_t size, const char *site_file, int64_t site_line, const char *site_kind);
void cyna_runtime_tracked_free(void *ptr);

/* Zero-copy construction path for owned dense payloads crossing the C ABI. */
CynaDense *cyna_dense_from_owned_parts(const CynaTypeDesc *elem_desc, unsigned char *data, int64_t len, int64_t cap);

CynaString cyna_runtime_string_new_uninit(int64_t len);
CynaString cyna_string_from_bytes(CynaBytes bytes);
CynaString cyna_string_copy(CynaString value);
CynaString cyna_string_share(CynaString value);
void cyna_string_release(CynaString value);
void cyna_string_share_into(CynaString *dst, const CynaString *src);
void cyna_string_release_at(const CynaString *value);
CynaString cyna_string_slice(CynaString value, int64_t start, int64_t end);
void cyna_string_from_bytes_into(CynaString *dst, const CynaBytes *bytes);
void cyna_string_slice_into(CynaString *dst, const CynaString *value, int64_t start, int64_t end);
void cyna_string_find_into(CynaOptionalI64 *dst, const char *string_ptr, int64_t string_len, const char *needle_ptr, int64_t needle_len);
void cyna_string_rfind_into(CynaOptionalI64 *dst, const char *string_ptr, int64_t string_len, const char *needle_ptr, int64_t needle_len);
CynaString cyna_runtime_fmt_empty(void);
CynaString cyna_runtime_fmt_append_string(CynaString acc, CynaString value);
CynaString cyna_runtime_fmt_append_int(CynaString acc, int64_t value, int32_t is_signed, int32_t format);
void cyna_runtime_fmt_empty_into(CynaString *dst);
void cyna_runtime_fmt_append_string_into(CynaString *dst, const CynaString *acc, const CynaString *value);
void cyna_runtime_fmt_append_int_into(CynaString *dst, const CynaString *acc, int64_t value, int32_t is_signed, int32_t format);
uint8_t cyna_sequence_eq(const void *lhs_ptr, int64_t lhs_len, const void *rhs_ptr, int64_t rhs_len, const CynaTypeDesc *elem_desc);
uint8_t cyna_sparse_eq(const void *lhs_data, const unsigned char *lhs_occupied, int64_t lhs_len, int64_t lhs_cap, const void *rhs_data, const unsigned char *rhs_occupied, int64_t rhs_len, int64_t rhs_cap, const CynaTypeDesc *elem_desc);

#endif

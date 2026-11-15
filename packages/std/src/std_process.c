#include "../../../src/runtime/cyna.h"
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <direct.h>
#include <io.h>
#include <process.h>
#include <windows.h>
#include <tlhelp32.h>
#else
#include <sys/wait.h>
#include <unistd.h>
#endif

#ifdef __APPLE__
extern int *_NSGetArgc(void);
extern char ***_NSGetArgv(void);
extern char ***_NSGetEnviron(void);
extern int _NSGetExecutablePath(char *buf, uint32_t *bufsize);
#endif
#if !defined(__APPLE__) && !defined(_WIN32)
extern char **environ;
#endif
extern uint8_t cyna_string_eq(const char *lhs_ptr, int64_t lhs_len, const char *rhs_ptr, int64_t rhs_len);

typedef enum {
    CYNA_PROCESS_NOT_FOUND = 0,
    CYNA_PROCESS_PERMISSION_DENIED = 1,
    CYNA_PROCESS_INVALID_ARGUMENT = 2,
    CYNA_PROCESS_INVALID_UTF8 = 3,
    CYNA_PROCESS_IO_ERROR = 4,
    CYNA_PROCESS_SPAWN_FAILED = 5,
    CYNA_PROCESS_WAIT_FAILED = 6,
} CynaProcessError;

typedef enum {
    CYNA_STDIO_INHERIT = 0,
    CYNA_STDIO_NULL = 1,
    CYNA_STDIO_PIPED = 2,
} CynaStdio;

typedef struct {
    unsigned char *data;
    int64_t len;
    int64_t cap;
} CynaOwnedDense;

typedef struct {
    unsigned char *data;
    int64_t len;
} CynaSlice;

typedef struct {
    CynaString key;
    CynaString value;
} CynaEnvPair;

typedef struct {
    uint8_t is_some;
    CynaString value;
} CynaOptionalString;

typedef struct {
    uint8_t is_some;
    uint32_t value;
} CynaOptionalU32;

typedef struct {
    uint8_t is_some;
    int32_t value;
} CynaOptionalI32;

typedef struct {
    CynaOptionalI32 code;
    uint8_t success;
} CynaExitStatus;

typedef struct {
    CynaExitStatus status;
    CynaString stdout_text;
    CynaString stderr_text;
} CynaOutput;

typedef struct {
    CynaString program;
    CynaSlice argv;
    CynaOptionalString cwd_path;
    CynaSlice env_pairs;
    uint8_t clear_env_flag;
    int32_t stdin_mode;
    int32_t stdout_mode;
    int32_t stderr_mode;
} CynaCommandBuilder;

typedef struct {
    uint8_t is_ok;
    CynaString ok;
    int32_t err;
} CynaResultStringProcessError;

typedef struct {
    uint8_t is_ok;
    uint32_t ok;
    int32_t err;
} CynaResultU32ProcessError;

typedef struct {
    uint8_t is_ok;
    CynaOptionalU32 ok;
    int32_t err;
} CynaResultOptionalU32ProcessError;

typedef struct {
    uint8_t is_ok;
    uint8_t ok;
    int32_t err;
} CynaResultBoolProcessError;

typedef struct {
    uint8_t is_ok;
    uint8_t ok;
    int32_t err;
} CynaResultVoidProcessError;

typedef struct {
    uint8_t is_ok;
    CynaDense *ok;
    int32_t err;
} CynaResultListEnvPairProcessError;

typedef struct {
    uint8_t is_ok;
    CynaExitStatus ok;
    int32_t err;
} CynaResultExitStatusProcessError;

typedef struct {
    uint8_t is_ok;
    CynaOutput ok;
    int32_t err;
} CynaResultOutputProcessError;

static void cyna_copy_env_pair(void *dst, const void *src, const CynaTypeDesc *desc) {
    (void)desc;
    const CynaEnvPair *in = (const CynaEnvPair *)src;
    CynaEnvPair *out = (CynaEnvPair *)dst;
    out->key = cyna_string_copy(in->key);
    out->value = cyna_string_copy(in->value);
}

static void cyna_drop_env_pair(void *value, const CynaTypeDesc *desc) {
    (void)desc;
    CynaEnvPair *pair = (CynaEnvPair *)value;
    cyna_string_release(pair->key);
    cyna_string_release(pair->value);
}

static uint8_t cyna_eq_env_pair(const void *lhs, const void *rhs, const CynaTypeDesc *desc) {
    (void)desc;
    const CynaEnvPair *a = (const CynaEnvPair *)lhs;
    const CynaEnvPair *b = (const CynaEnvPair *)rhs;
    return cyna_string_eq(a->key.ptr, a->key.len, b->key.ptr, b->key.len) &&
        cyna_string_eq(a->value.ptr, a->value.len, b->value.ptr, b->value.len);
}

static uint64_t cyna_hash_env_pair(const void *value, const CynaTypeDesc *desc) {
    (void)desc;
    const CynaEnvPair *pair = (const CynaEnvPair *)value;
    uint64_t left = 1469598103934665603ULL;
    uint64_t right = 1469598103934665603ULL;
    const int64_t key_len = cyna_string_logical_len(pair->key);
    const int64_t value_len = cyna_string_logical_len(pair->value);
    for (int64_t i = 0; i < key_len; i += 1) {
        left ^= (uint8_t)pair->key.ptr[i];
        left *= 1099511628211ULL;
    }
    for (int64_t i = 0; i < value_len; i += 1) {
        right ^= (uint8_t)pair->value.ptr[i];
        right *= 1099511628211ULL;
    }
    return left ^ (right + 0x9e3779b97f4a7c15ULL + (left << 6) + (left >> 2));
}

static const CynaTypeDesc cyna_desc_env_pair = {
    sizeof(CynaEnvPair),
    sizeof(void *),
    0,
    cyna_copy_env_pair,
    cyna_drop_env_pair,
    cyna_eq_env_pair,
    cyna_hash_env_pair,
    NULL,
};

static CynaProcessError cyna_map_process_errno(int err) {
    switch (err) {
        case ENOENT:
            return CYNA_PROCESS_NOT_FOUND;
        case EACCES:
        case EPERM:
            return CYNA_PROCESS_PERMISSION_DENIED;
        case EINVAL:
            return CYNA_PROCESS_INVALID_ARGUMENT;
        default:
            return CYNA_PROCESS_IO_ERROR;
    }
}

static CynaString cyna_copy_bytes_as_string(const char *ptr, int64_t len) {
    CynaString value = cyna_runtime_string_new_uninit(len);
    if (len != 0) memcpy((char *)value.ptr, ptr, (size_t)len);
    return value;
}

static char *cyna_path_buf(CynaString path) {
    const int64_t len = cyna_string_logical_len(path);
    char *buf = (char *)malloc((size_t)len + 1u);
    if (buf == NULL) return NULL;
    memcpy(buf, path.ptr, (size_t)len);
    buf[len] = '\0';
    return buf;
}

static int cyna_is_valid_utf8(const unsigned char *ptr, size_t len) {
    size_t i = 0;
    while (i < len) {
        unsigned char b0 = ptr[i];
        if (b0 <= 0x7f) {
            i += 1;
            continue;
        }
        if ((b0 & 0xe0u) == 0xc0u) {
            if (i + 1 >= len) return 0;
            unsigned char b1 = ptr[i + 1];
            if ((b1 & 0xc0u) != 0x80u) return 0;
            if (b0 < 0xc2u) return 0;
            i += 2;
            continue;
        }
        if ((b0 & 0xf0u) == 0xe0u) {
            if (i + 2 >= len) return 0;
            unsigned char b1 = ptr[i + 1];
            unsigned char b2 = ptr[i + 2];
            if ((b1 & 0xc0u) != 0x80u || (b2 & 0xc0u) != 0x80u) return 0;
            if (b0 == 0xe0u && b1 < 0xa0u) return 0;
            if (b0 == 0xedu && b1 >= 0xa0u) return 0;
            i += 3;
            continue;
        }
        if ((b0 & 0xf8u) == 0xf0u) {
            if (i + 3 >= len) return 0;
            unsigned char b1 = ptr[i + 1];
            unsigned char b2 = ptr[i + 2];
            unsigned char b3 = ptr[i + 3];
            if ((b1 & 0xc0u) != 0x80u || (b2 & 0xc0u) != 0x80u || (b3 & 0xc0u) != 0x80u) return 0;
            if (b0 == 0xf0u && b1 < 0x90u) return 0;
            if (b0 > 0xf4u) return 0;
            if (b0 == 0xf4u && b1 >= 0x90u) return 0;
            i += 4;
            continue;
        }
        return 0;
    }
    return 1;
}

static CynaOptionalString cyna_optional_string_none(void) {
    CynaOptionalString out;
    out.is_some = 0;
    out.value.ptr = NULL;
    out.value.len = 0;
    return out;
}

static CynaOptionalString cyna_optional_string_some(CynaString value) {
    CynaOptionalString out;
    out.is_some = 1;
    out.value = value;
    return out;
}

static CynaOptionalU32 cyna_optional_u32_none(void) {
    CynaOptionalU32 out;
    out.is_some = 0;
    out.value = 0;
    return out;
}

static CynaOptionalU32 cyna_optional_u32_some(uint32_t value) {
    CynaOptionalU32 out;
    out.is_some = 1;
    out.value = value;
    return out;
}

static CynaOptionalI32 cyna_optional_i32_none(void) {
    CynaOptionalI32 out;
    out.is_some = 0;
    out.value = 0;
    return out;
}

static CynaOptionalI32 cyna_optional_i32_some(int32_t value) {
    CynaOptionalI32 out;
    out.is_some = 1;
    out.value = value;
    return out;
}

#ifndef _WIN32
static CynaExitStatus cyna_make_exit_status_from_wait(int status) {
    CynaExitStatus out;
    if (WIFEXITED(status)) {
        out.code = cyna_optional_i32_some(WEXITSTATUS(status));
        out.success = (WEXITSTATUS(status) == 0) ? 1 : 0;
        return out;
    }
    out.code = cyna_optional_i32_none();
    out.success = 0;
    return out;
}
#endif

static CynaResultStringProcessError cyna_result_string_ok(CynaString value) {
    CynaResultStringProcessError out;
    out.is_ok = 0;
    out.ok = value;
    out.err = CYNA_PROCESS_IO_ERROR;
    return out;
}

static CynaResultStringProcessError cyna_result_string_err(CynaProcessError err) {
    CynaResultStringProcessError out;
    out.is_ok = 1;
    out.ok.ptr = NULL;
    out.ok.len = 0;
    out.err = (int32_t)err;
    return out;
}

static CynaResultU32ProcessError cyna_result_u32_ok(uint32_t value) {
    CynaResultU32ProcessError out;
    out.is_ok = 0;
    out.ok = value;
    out.err = CYNA_PROCESS_IO_ERROR;
    return out;
}

static CynaResultU32ProcessError cyna_result_u32_err(CynaProcessError err) {
    CynaResultU32ProcessError out;
    out.is_ok = 1;
    out.ok = 0;
    out.err = (int32_t)err;
    return out;
}

static CynaResultOptionalU32ProcessError cyna_result_optional_u32_ok(CynaOptionalU32 value) {
    CynaResultOptionalU32ProcessError out;
    out.is_ok = 0;
    out.ok = value;
    out.err = CYNA_PROCESS_IO_ERROR;
    return out;
}

static CynaResultOptionalU32ProcessError cyna_result_optional_u32_err(CynaProcessError err) {
    CynaResultOptionalU32ProcessError out;
    out.is_ok = 1;
    out.ok = cyna_optional_u32_none();
    out.err = (int32_t)err;
    return out;
}

static CynaResultBoolProcessError cyna_result_bool_ok(uint8_t value) {
    CynaResultBoolProcessError out;
    out.is_ok = 0;
    out.ok = value != 0;
    out.err = CYNA_PROCESS_IO_ERROR;
    return out;
}

static CynaResultBoolProcessError cyna_result_bool_err(CynaProcessError err) {
    CynaResultBoolProcessError out;
    out.is_ok = 1;
    out.ok = 0;
    out.err = (int32_t)err;
    return out;
}

static CynaResultVoidProcessError cyna_result_void_ok(void) {
    CynaResultVoidProcessError out;
    out.is_ok = 0;
    out.ok = 0;
    out.err = CYNA_PROCESS_IO_ERROR;
    return out;
}

static CynaResultVoidProcessError cyna_result_void_err(CynaProcessError err) {
    CynaResultVoidProcessError out;
    out.is_ok = 1;
    out.ok = 0;
    out.err = (int32_t)err;
    return out;
}

static CynaResultListEnvPairProcessError cyna_result_list_env_pair_ok(CynaDense *value) {
    CynaResultListEnvPairProcessError out;
    out.is_ok = 0;
    out.ok = value;
    out.err = CYNA_PROCESS_IO_ERROR;
    return out;
}

static CynaResultListEnvPairProcessError cyna_result_list_env_pair_err(CynaProcessError err) {
    CynaResultListEnvPairProcessError out;
    out.is_ok = 1;
    out.ok = NULL;
    out.err = (int32_t)err;
    return out;
}

static CynaResultExitStatusProcessError cyna_result_exit_status_ok(CynaExitStatus value) {
    CynaResultExitStatusProcessError out;
    out.is_ok = 0;
    out.ok = value;
    out.err = CYNA_PROCESS_IO_ERROR;
    return out;
}

static CynaResultExitStatusProcessError cyna_result_exit_status_err(CynaProcessError err) {
    CynaResultExitStatusProcessError out;
    out.is_ok = 1;
    out.ok.code = cyna_optional_i32_none();
    out.ok.success = 0;
    out.err = (int32_t)err;
    return out;
}

static CynaResultOutputProcessError cyna_result_output_ok(CynaOutput value) {
    CynaResultOutputProcessError out;
    out.is_ok = 0;
    out.ok = value;
    out.err = CYNA_PROCESS_IO_ERROR;
    return out;
}

static CynaResultOutputProcessError cyna_result_output_err(CynaProcessError err) {
    CynaResultOutputProcessError out;
    out.is_ok = 1;
    out.ok.status.code = cyna_optional_i32_none();
    out.ok.status.success = 0;
    out.ok.stdout_text.ptr = NULL;
    out.ok.stdout_text.len = 0;
    out.ok.stderr_text.ptr = NULL;
    out.ok.stderr_text.len = 0;
    out.err = (int32_t)err;
    return out;
}

static CynaOwnedDense cyna_alloc_dense(int64_t elem_size, int64_t len) {
    CynaOwnedDense dense;
    dense.data = NULL;
    dense.len = len;
    dense.cap = len;
    if (len != 0) {
        dense.data = (unsigned char *)cyna_runtime_tracked_alloc_site((size_t)(len * elem_size), __FILE__, __LINE__, "std.process.dense.data");
    }
    return dense;
}

static CynaDense *cyna_export_dense(const CynaTypeDesc *elem_desc, CynaOwnedDense dense) {
    CynaDense *out = (CynaDense *)cyna_runtime_tracked_alloc_site(sizeof(CynaDense), __FILE__, __LINE__, "std.process.dense");
    if (out == NULL) {
        cyna_runtime_tracked_free(dense.data);
        return NULL;
    }
    out->elem_desc = elem_desc;
    out->len = dense.len;
    out->cap = dense.cap;
    out->data = dense.data;
    return out;
}

static CynaDense *cyna_build_args_dense(void) {
#ifdef _WIN32
    int argc = __argc;
    char **argv = __argv;
#elif defined(__APPLE__)
    int *argc_ptr = _NSGetArgc();
    char ***argv_ptr = _NSGetArgv();
    if (argc_ptr == NULL || argv_ptr == NULL || *argv_ptr == NULL || *argc_ptr <= 0) {
        return cyna_export_dense(&cyna_desc_string, cyna_alloc_dense(sizeof(CynaString), 0));
    }
    int argc = *argc_ptr;
    char **argv = *argv_ptr;
#else
    FILE *file = fopen("/proc/self/cmdline", "rb");
    if (file == NULL) {
        return cyna_export_dense(&cyna_desc_string, cyna_alloc_dense(sizeof(CynaString), 0));
    }
    unsigned char *buffer = NULL;
    size_t size = 0;
    size_t capacity = 0;
    for (;;) {
        if (size == capacity) {
            size_t next = capacity == 0 ? 256u : capacity * 2u;
            unsigned char *grown = (unsigned char *)realloc(buffer, next);
            if (grown == NULL) {
                free(buffer);
                fclose(file);
                return NULL;
            }
            buffer = grown;
            capacity = next;
        }
        size_t got = fread(buffer + size, 1, capacity - size, file);
        size += got;
        if (got == 0) break;
    }
    fclose(file);
    int64_t count = 0;
    size_t start = 0;
    for (size_t i = 0; i < size; i += 1) {
        if (buffer[i] != 0) continue;
        if (i > start) count += 1;
        start = i + 1;
    }
    CynaOwnedDense dense = cyna_alloc_dense(sizeof(CynaString), count);
    if (count != 0 && dense.data == NULL) {
        free(buffer);
        return NULL;
    }
    CynaString *items = (CynaString *)dense.data;
    int64_t index = 0;
    start = 0;
    for (size_t i = 0; i < size; i += 1) {
        if (buffer[i] != 0) continue;
        if (i > start) {
            items[index++] = cyna_copy_bytes_as_string((const char *)buffer + start, (int64_t)(i - start));
        }
        start = i + 1;
    }
    free(buffer);
    return cyna_export_dense(&cyna_desc_string, dense);
#endif
#if defined(_WIN32) || defined(__APPLE__)
    if (argc <= 0 || argv == NULL) {
        return cyna_export_dense(&cyna_desc_string, cyna_alloc_dense(sizeof(CynaString), 0));
    }
    int64_t count = (int64_t)argc;
    CynaOwnedDense dense = cyna_alloc_dense(sizeof(CynaString), count);
    if (count != 0 && dense.data == NULL) return NULL;
    CynaString *items = (CynaString *)dense.data;
    for (int64_t i = 0; i < count; i += 1) {
        char *text = argv[i];
        items[i] = cyna_copy_bytes_as_string(text, (int64_t)strlen(text));
    }
    return cyna_export_dense(&cyna_desc_string, dense);
#endif
}

static CynaResultListEnvPairProcessError cyna_build_env_list(void) {
#ifdef _WIN32
    char **envp = _environ;
#elif defined(__APPLE__)
    char **envp = *_NSGetEnviron();
#else
    char **envp = environ;
#endif
    int64_t count = 0;
    if (envp != NULL) {
        while (envp[count] != NULL) count += 1;
    }
    CynaOwnedDense dense = cyna_alloc_dense(sizeof(CynaEnvPair), count);
    if (count != 0 && dense.data == NULL) return cyna_result_list_env_pair_err(CYNA_PROCESS_IO_ERROR);
    CynaEnvPair *items = dense.data != NULL ? (CynaEnvPair *)dense.data : NULL;
    for (int64_t i = 0; i < count; i += 1) {
        const char *entry = envp[i];
        const char *sep = strchr(entry, '=');
        int64_t key_len = sep == NULL ? (int64_t)strlen(entry) : (int64_t)(sep - entry);
        int64_t value_len = sep == NULL ? 0 : (int64_t)strlen(sep + 1);
        items[i].key = cyna_copy_bytes_as_string(entry, key_len);
        items[i].value = cyna_copy_bytes_as_string(sep == NULL ? "" : sep + 1, value_len);
    }
    CynaDense *out = cyna_export_dense(&cyna_desc_env_pair, dense);
    if (out == NULL) return cyna_result_list_env_pair_err(CYNA_PROCESS_IO_ERROR);
    return cyna_result_list_env_pair_ok(out);
}

static char **cyna_command_argv(CynaCommandBuilder command) {
    int64_t extra = command.argv.len;
    char **argv = (char **)malloc(sizeof(char *) * (size_t)(extra + 2));
    if (argv == NULL) return NULL;
    argv[0] = cyna_path_buf(command.program);
    if (argv[0] == NULL) {
        free(argv);
        return NULL;
    }
    CynaString *items = command.argv.data != NULL ? (CynaString *)command.argv.data : NULL;
    for (int64_t i = 0; i < extra; i += 1) {
        argv[i + 1] = cyna_path_buf(items[i]);
        if (argv[i + 1] == NULL) {
            for (int64_t j = 0; j <= i; j += 1) free(argv[j]);
            free(argv);
            return NULL;
        }
    }
    argv[extra + 1] = NULL;
    return argv;
}

static void cyna_free_argv(char **argv) {
    if (argv == NULL) return;
    for (size_t i = 0; argv[i] != NULL; i += 1) free(argv[i]);
    free(argv);
}

#ifdef _WIN32
static void cyna_win_append_quoted(char *out, size_t *cursor, const char *arg) {
    out[(*cursor)++] = '"';
    size_t backslashes = 0;
    for (const char *p = arg; *p != '\0'; p += 1) {
        if (*p == '\\') {
            backslashes += 1;
            continue;
        }
        if (*p == '"') {
            size_t count = backslashes * 2u + 1u;
            for (size_t i = 0; i < count; i += 1) out[(*cursor)++] = '\\';
            out[(*cursor)++] = '"';
            backslashes = 0;
            continue;
        }
        for (size_t i = 0; i < backslashes; i += 1) out[(*cursor)++] = '\\';
        backslashes = 0;
        out[(*cursor)++] = *p;
    }
    for (size_t i = 0; i < backslashes * 2u; i += 1) out[(*cursor)++] = '\\';
    out[(*cursor)++] = '"';
}

static char *cyna_win_command_line(char **argv) {
    size_t total = 1;
    for (size_t i = 0; argv[i] != NULL; i += 1) total += strlen(argv[i]) * 2u + 4u;
    char *line = (char *)malloc(total);
    if (line == NULL) return NULL;
    size_t cursor = 0;
    for (size_t i = 0; argv[i] != NULL; i += 1) {
        if (i != 0) line[cursor++] = ' ';
        cyna_win_append_quoted(line, &cursor, argv[i]);
    }
    line[cursor] = '\0';
    return line;
}

static char *cyna_win_dup(const char *text) {
    size_t len = strlen(text);
    char *out = (char *)malloc(len + 1u);
    if (out == NULL) return NULL;
    memcpy(out, text, len + 1u);
    return out;
}

static int cyna_win_env_push(char ***entries, size_t *count, size_t *capacity, char *entry) {
    if (*count == *capacity) {
        size_t next = *capacity == 0 ? 16u : *capacity * 2u;
        char **grown = (char **)realloc(*entries, next * sizeof(char *));
        if (grown == NULL) return 0;
        *entries = grown;
        *capacity = next;
    }
    (*entries)[(*count)++] = entry;
    return 1;
}

static char *cyna_win_env_block(const CynaCommandBuilder *command) {
    char **entries = NULL;
    size_t count = 0;
    size_t capacity = 0;
    if (!command->clear_env_flag) {
        for (char **item = _environ; item != NULL && *item != NULL; item += 1) {
            char *copy = cyna_win_dup(*item);
            if (copy == NULL || !cyna_win_env_push(&entries, &count, &capacity, copy)) {
                free(copy);
                goto fail;
            }
        }
    }
    CynaEnvPair *pairs = command->env_pairs.data != NULL ? (CynaEnvPair *)command->env_pairs.data : NULL;
    for (int64_t i = 0; i < command->env_pairs.len; i += 1) {
        char *key = cyna_path_buf(pairs[i].key);
        char *value = cyna_path_buf(pairs[i].value);
        if (key == NULL || value == NULL) {
            free(key);
            free(value);
            goto fail;
        }
        size_t key_len = strlen(key);
        for (size_t j = 0; j < count;) {
            if (strncmp(entries[j], key, key_len) == 0 && entries[j][key_len] == '=') {
                free(entries[j]);
                memmove(&entries[j], &entries[j + 1], (count - j - 1u) * sizeof(char *));
                count -= 1u;
                continue;
            }
            j += 1;
        }
        size_t entry_len = key_len + 1u + strlen(value);
        char *entry = (char *)malloc(entry_len + 1u);
        if (entry == NULL) {
            free(key);
            free(value);
            goto fail;
        }
        memcpy(entry, key, key_len);
        entry[key_len] = '=';
        memcpy(entry + key_len + 1u, value, strlen(value) + 1u);
        free(key);
        free(value);
        if (!cyna_win_env_push(&entries, &count, &capacity, entry)) {
            free(entry);
            goto fail;
        }
    }
    size_t size = 2;
    for (size_t i = 0; i < count; i += 1) size += strlen(entries[i]) + 1u;
    char *block = (char *)malloc(size);
    if (block == NULL) goto fail;
    size_t cursor = 0;
    for (size_t i = 0; i < count; i += 1) {
        size_t len = strlen(entries[i]) + 1u;
        memcpy(block + cursor, entries[i], len);
        cursor += len;
    }
    block[cursor] = '\0';
    for (size_t i = 0; i < count; i += 1) free(entries[i]);
    free(entries);
    return block;
fail:
    for (size_t i = 0; i < count; i += 1) free(entries[i]);
    free(entries);
    return NULL;
}

static CynaProcessError cyna_win_spawn(CynaCommandBuilder command, int stdin_fd, int stdout_fd, int stderr_fd, HANDLE *process_out) {
    char **argv = cyna_command_argv(command);
    if (argv == NULL) return CYNA_PROCESS_SPAWN_FAILED;
    char *line = cyna_win_command_line(argv);
    cyna_free_argv(argv);
    if (line == NULL) return CYNA_PROCESS_SPAWN_FAILED;
    char *env_block = NULL;
    if (command.clear_env_flag || command.env_pairs.data != NULL) {
        env_block = cyna_win_env_block(&command);
        if (env_block == NULL) {
            free(line);
            return CYNA_PROCESS_SPAWN_FAILED;
        }
    }
    char *cwd = NULL;
    if (command.cwd_path.is_some) {
        cwd = cyna_path_buf(command.cwd_path.value);
        if (cwd == NULL) {
            free(env_block);
            free(line);
            return CYNA_PROCESS_SPAWN_FAILED;
        }
    }

    STARTUPINFOA info;
    memset(&info, 0, sizeof(info));
    info.cb = sizeof(info);
    info.dwFlags = STARTF_USESTDHANDLES;
    HANDLE nul_in = INVALID_HANDLE_VALUE;
    HANDLE nul_out = INVALID_HANDLE_VALUE;
    HANDLE nul_err = INVALID_HANDLE_VALUE;
    HANDLE stdin_h = GetStdHandle(STD_INPUT_HANDLE);
    HANDLE stdout_h = GetStdHandle(STD_OUTPUT_HANDLE);
    HANDLE stderr_h = GetStdHandle(STD_ERROR_HANDLE);
    if (stdin_fd >= 0) stdin_h = (HANDLE)_get_osfhandle(stdin_fd);
    else if (command.stdin_mode == CYNA_STDIO_NULL) {
        nul_in = CreateFileA("NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
        stdin_h = nul_in;
    }
    if (stdout_fd >= 0) stdout_h = (HANDLE)_get_osfhandle(stdout_fd);
    else if (command.stdout_mode == CYNA_STDIO_NULL) {
        nul_out = CreateFileA("NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
        stdout_h = nul_out;
    }
    if (stderr_fd >= 0) stderr_h = (HANDLE)_get_osfhandle(stderr_fd);
    else if (command.stderr_mode == CYNA_STDIO_NULL) {
        nul_err = CreateFileA("NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
        stderr_h = nul_err;
    }
    if (stdin_h != INVALID_HANDLE_VALUE && stdin_h != NULL) SetHandleInformation(stdin_h, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
    if (stdout_h != INVALID_HANDLE_VALUE && stdout_h != NULL) SetHandleInformation(stdout_h, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
    if (stderr_h != INVALID_HANDLE_VALUE && stderr_h != NULL) SetHandleInformation(stderr_h, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
    info.hStdInput = stdin_h;
    info.hStdOutput = stdout_h;
    info.hStdError = stderr_h;

    PROCESS_INFORMATION process_info;
    memset(&process_info, 0, sizeof(process_info));
    BOOL ok = CreateProcessA(NULL, line, NULL, NULL, TRUE, 0, env_block, cwd, &info, &process_info);
    DWORD last_error = GetLastError();
    if (nul_in != INVALID_HANDLE_VALUE) CloseHandle(nul_in);
    if (nul_out != INVALID_HANDLE_VALUE) CloseHandle(nul_out);
    if (nul_err != INVALID_HANDLE_VALUE) CloseHandle(nul_err);
    free(cwd);
    free(env_block);
    free(line);
    if (!ok) {
        if (last_error == ERROR_FILE_NOT_FOUND || last_error == ERROR_PATH_NOT_FOUND) return CYNA_PROCESS_NOT_FOUND;
        if (last_error == ERROR_ACCESS_DENIED) return CYNA_PROCESS_PERMISSION_DENIED;
        return CYNA_PROCESS_SPAWN_FAILED;
    }
    CloseHandle(process_info.hThread);
    *process_out = process_info.hProcess;
    return CYNA_PROCESS_IO_ERROR;
}

static CynaProcessError cyna_win_wait(HANDLE process, CynaExitStatus *status_out) {
    if (process == NULL) return CYNA_PROCESS_WAIT_FAILED;
    DWORD exit_code = 0;
    if (WaitForSingleObject(process, INFINITE) != WAIT_OBJECT_0) {
        CloseHandle(process);
        return CYNA_PROCESS_WAIT_FAILED;
    }
    if (!GetExitCodeProcess(process, &exit_code)) {
        CloseHandle(process);
        return CYNA_PROCESS_WAIT_FAILED;
    }
    CloseHandle(process);
    status_out->code = cyna_optional_i32_some((int32_t)exit_code);
    status_out->success = exit_code == 0 ? 1 : 0;
    return CYNA_PROCESS_IO_ERROR;
}
#endif

#ifndef _WIN32
static int cyna_apply_child_process(CynaCommandBuilder command, int stdin_fd, int stdout_fd, int stderr_fd, int exec_error_fd) {
    if (stdin_fd >= 0 && dup2(stdin_fd, STDIN_FILENO) < 0) return errno;
    if (stdout_fd >= 0 && dup2(stdout_fd, STDOUT_FILENO) < 0) return errno;
    if (stderr_fd >= 0 && dup2(stderr_fd, STDERR_FILENO) < 0) return errno;

    if (command.stdin_mode == CYNA_STDIO_NULL && stdin_fd < 0) {
        int fd = open("/dev/null", O_RDONLY);
        if (fd < 0) return errno;
        if (dup2(fd, STDIN_FILENO) < 0) {
            int err = errno;
            close(fd);
            return err;
        }
        close(fd);
    }
    if (command.stdout_mode == CYNA_STDIO_NULL && stdout_fd < 0) {
        int fd = open("/dev/null", O_WRONLY);
        if (fd < 0) return errno;
        if (dup2(fd, STDOUT_FILENO) < 0) {
            int err = errno;
            close(fd);
            return err;
        }
        close(fd);
    }
    if (command.stderr_mode == CYNA_STDIO_NULL && stderr_fd < 0) {
        int fd = open("/dev/null", O_WRONLY);
        if (fd < 0) return errno;
        if (dup2(fd, STDERR_FILENO) < 0) {
            int err = errno;
            close(fd);
            return err;
        }
        close(fd);
    }

    if (command.cwd_path.is_some) {
        char *cwd = cyna_path_buf(command.cwd_path.value);
        if (cwd == NULL) return ENOMEM;
        if (chdir(cwd) != 0) {
            int err = errno;
            free(cwd);
            return err;
        }
        free(cwd);
    }

    if (command.clear_env_flag) {
        static char *empty_env[] = { NULL };
#ifdef __APPLE__
        *_NSGetEnviron() = empty_env;
#else
        environ = empty_env;
#endif
    }

    if (command.env_pairs.data != NULL) {
        CynaEnvPair *pairs = (CynaEnvPair *)command.env_pairs.data;
        for (int64_t i = 0; i < command.env_pairs.len; i += 1) {
            char *key = cyna_path_buf(pairs[i].key);
            char *value = cyna_path_buf(pairs[i].value);
            if (key == NULL || value == NULL) {
                free(key);
                free(value);
                return ENOMEM;
            }
            if (setenv(key, value, 1) != 0) {
                int err = errno;
                free(key);
                free(value);
                return err;
            }
            free(key);
            free(value);
        }
    }

    char **argv = cyna_command_argv(command);
    if (argv == NULL) return ENOMEM;
    execvp(argv[0], argv);
    int err = errno;
    cyna_free_argv(argv);
    return err;
}

static CynaProcessError cyna_wait_for_child(pid_t pid, int exec_error_read, CynaExitStatus *status_out) {
    int wait_status = 0;
    if (waitpid(pid, &wait_status, 0) < 0) return CYNA_PROCESS_WAIT_FAILED;
    int child_err = 0;
    ssize_t got = read(exec_error_read, &child_err, sizeof(child_err));
    if (got > 0) return CYNA_PROCESS_SPAWN_FAILED;
    *status_out = cyna_make_exit_status_from_wait(wait_status);
    return CYNA_PROCESS_IO_ERROR;
}
#endif

static CynaResultStringProcessError cyna_read_tmpfile_string(FILE *file) {
    if (fflush(file) != 0) return cyna_result_string_err(CYNA_PROCESS_IO_ERROR);
    if (fseek(file, 0, SEEK_END) != 0) return cyna_result_string_err(CYNA_PROCESS_IO_ERROR);
    long size_long = ftell(file);
    if (size_long < 0) return cyna_result_string_err(CYNA_PROCESS_IO_ERROR);
    if (fseek(file, 0, SEEK_SET) != 0) return cyna_result_string_err(CYNA_PROCESS_IO_ERROR);

    size_t size = (size_t)size_long;
    unsigned char *buf = NULL;
    if (size != 0) {
        buf = (unsigned char *)malloc(size);
        if (buf == NULL) return cyna_result_string_err(CYNA_PROCESS_IO_ERROR);
        if (fread(buf, 1, size, file) != size) {
            free(buf);
            return cyna_result_string_err(CYNA_PROCESS_IO_ERROR);
        }
        if (!cyna_is_valid_utf8(buf, size)) {
            free(buf);
            return cyna_result_string_err(CYNA_PROCESS_INVALID_UTF8);
        }
    }
    CynaString out = cyna_copy_bytes_as_string((const char *)(buf == NULL ? "" : (const char *)buf), (int64_t)size);
    free(buf);
    return cyna_result_string_ok(out);
}

CynaDense *cyna_std_process_args_dense(void) {
    return cyna_build_args_dense();
}

CynaResultStringProcessError cyna_std_process_cwd(void) {
    size_t size = 256;
    for (;;) {
        char *buf = (char *)malloc(size);
        if (buf == NULL) return cyna_result_string_err(CYNA_PROCESS_IO_ERROR);
#ifdef _WIN32
        if (_getcwd(buf, (int)size) != NULL) {
#else
        if (getcwd(buf, size) != NULL) {
#endif
            CynaString out = cyna_copy_bytes_as_string(buf, (int64_t)strlen(buf));
            free(buf);
            return cyna_result_string_ok(out);
        }
        int err = errno;
        free(buf);
        if (err != ERANGE) return cyna_result_string_err(cyna_map_process_errno(err));
        size *= 2;
    }
}

CynaResultStringProcessError cyna_std_process_exe_path(void) {
#ifdef _WIN32
    size_t size = 256;
    for (;;) {
        char *buf = (char *)malloc(size);
        if (buf == NULL) return cyna_result_string_err(CYNA_PROCESS_IO_ERROR);
        DWORD written = GetModuleFileNameA(NULL, buf, (DWORD)size);
        if (written == 0) {
            free(buf);
            return cyna_result_string_err(CYNA_PROCESS_IO_ERROR);
        }
        if ((size_t)written < size) {
            CynaString out = cyna_copy_bytes_as_string(buf, (int64_t)written);
            free(buf);
            return cyna_result_string_ok(out);
        }
        free(buf);
        if (size > 32768u) return cyna_result_string_err(CYNA_PROCESS_IO_ERROR);
        size *= 2u;
    }
#elif defined(__APPLE__)
    uint32_t size = 0;
    (void)_NSGetExecutablePath(NULL, &size);
    char *buf = (char *)malloc(size);
    if (buf == NULL) return cyna_result_string_err(CYNA_PROCESS_IO_ERROR);
    if (_NSGetExecutablePath(buf, &size) != 0) {
        free(buf);
        return cyna_result_string_err(CYNA_PROCESS_IO_ERROR);
    }
    char *resolved = realpath(buf, NULL);
    const char *text = resolved != NULL ? resolved : buf;
    CynaString out = cyna_copy_bytes_as_string(text, (int64_t)strlen(text));
    free(resolved);
    free(buf);
    return cyna_result_string_ok(out);
#else
    size_t size = 256;
    for (;;) {
        char *buf = (char *)malloc(size);
        if (buf == NULL) return cyna_result_string_err(CYNA_PROCESS_IO_ERROR);
        ssize_t got = readlink("/proc/self/exe", buf, size);
        if (got < 0) {
            free(buf);
            return cyna_result_string_err(CYNA_PROCESS_IO_ERROR);
        }
        if ((size_t)got < size) {
            CynaString out = cyna_copy_bytes_as_string(buf, (int64_t)got);
            free(buf);
            return cyna_result_string_ok(out);
        }
        free(buf);
        if (size > 32768u) return cyna_result_string_err(CYNA_PROCESS_IO_ERROR);
        size *= 2u;
    }
#endif
}

CynaResultU32ProcessError cyna_std_process_pid(void) {
#ifdef _WIN32
    return cyna_result_u32_ok((uint32_t)GetCurrentProcessId());
#else
    return cyna_result_u32_ok((uint32_t)getpid());
#endif
}

CynaResultOptionalU32ProcessError cyna_std_process_parent_pid(void) {
#ifdef _WIN32
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return cyna_result_optional_u32_err(CYNA_PROCESS_IO_ERROR);
    PROCESSENTRY32 entry;
    memset(&entry, 0, sizeof(entry));
    entry.dwSize = sizeof(entry);
    DWORD self = GetCurrentProcessId();
    DWORD parent = 0;
    if (Process32First(snapshot, &entry)) {
        do {
            if (entry.th32ProcessID == self) {
                parent = entry.th32ParentProcessID;
                break;
            }
        } while (Process32Next(snapshot, &entry));
    }
    CloseHandle(snapshot);
    if (parent == 0) return cyna_result_optional_u32_err(CYNA_PROCESS_IO_ERROR);
    return cyna_result_optional_u32_ok(cyna_optional_u32_some((uint32_t)parent));
#else
    pid_t value = getppid();
    if (value < 0) return cyna_result_optional_u32_err(CYNA_PROCESS_IO_ERROR);
    return cyna_result_optional_u32_ok(cyna_optional_u32_some((uint32_t)value));
#endif
}

CynaOptionalString cyna_std_process_env_get(CynaString key) {
    CynaOptionalString out = cyna_optional_string_none();
    char *key_buf = cyna_path_buf(key);
    if (key_buf == NULL) return out;
    const char *value = getenv(key_buf);
    free(key_buf);
    if (value == NULL) return out;
    return cyna_optional_string_some(cyna_copy_bytes_as_string(value, (int64_t)strlen(value)));
}

CynaResultVoidProcessError cyna_std_process_env_set(CynaString key, CynaString value) {
    char *key_buf = cyna_path_buf(key);
    char *value_buf = cyna_path_buf(value);
    if (key_buf == NULL || value_buf == NULL) {
        free(key_buf);
        free(value_buf);
        return cyna_result_void_err(CYNA_PROCESS_IO_ERROR);
    }
#ifdef _WIN32
    int set_rc = _putenv_s(key_buf, value_buf);
#else
    int set_rc = setenv(key_buf, value_buf, 1);
#endif
    if (set_rc != 0) {
        int err = errno;
        free(key_buf);
        free(value_buf);
        return cyna_result_void_err(cyna_map_process_errno(err));
    }
    free(key_buf);
    free(value_buf);
    return cyna_result_void_ok();
}

CynaResultVoidProcessError cyna_std_process_env_unset(CynaString key) {
    char *key_buf = cyna_path_buf(key);
    if (key_buf == NULL) return cyna_result_void_err(CYNA_PROCESS_IO_ERROR);
#ifdef _WIN32
    int unset_rc = _putenv_s(key_buf, "");
#else
    int unset_rc = unsetenv(key_buf);
#endif
    if (unset_rc != 0) {
        int err = errno;
        free(key_buf);
        return cyna_result_void_err(cyna_map_process_errno(err));
    }
    free(key_buf);
    return cyna_result_void_ok();
}

CynaResultListEnvPairProcessError cyna_std_process_env_list_dense(void) {
    return cyna_build_env_list();
}

CynaResultBoolProcessError cyna_std_process_stdin_is_tty(void) {
#ifdef _WIN32
    return cyna_result_bool_ok(_isatty(_fileno(stdin)) ? 1 : 0);
#else
    return cyna_result_bool_ok(isatty(STDIN_FILENO) ? 1 : 0);
#endif
}

CynaResultBoolProcessError cyna_std_process_stdout_is_tty(void) {
#ifdef _WIN32
    return cyna_result_bool_ok(_isatty(_fileno(stdout)) ? 1 : 0);
#else
    return cyna_result_bool_ok(isatty(STDOUT_FILENO) ? 1 : 0);
#endif
}

CynaResultBoolProcessError cyna_std_process_stderr_is_tty(void) {
#ifdef _WIN32
    return cyna_result_bool_ok(_isatty(_fileno(stderr)) ? 1 : 0);
#else
    return cyna_result_bool_ok(isatty(STDERR_FILENO) ? 1 : 0);
#endif
}

void cyna_std_process_exit(int32_t code) {
    exit(code);
}

#ifdef _WIN32
CynaResultExitStatusProcessError cyna_std_process_run_raw(CynaCommandBuilder command) {
    if (command.stdin_mode == CYNA_STDIO_PIPED) return cyna_result_exit_status_err(CYNA_PROCESS_INVALID_ARGUMENT);

    FILE *stdout_capture = NULL;
    FILE *stderr_capture = NULL;
    int stdout_fd = -1;
    int stderr_fd = -1;
    if (command.stdout_mode == CYNA_STDIO_PIPED) {
        stdout_capture = tmpfile();
        if (stdout_capture == NULL) return cyna_result_exit_status_err(CYNA_PROCESS_IO_ERROR);
        stdout_fd = fileno(stdout_capture);
    }
    if (command.stderr_mode == CYNA_STDIO_PIPED) {
        stderr_capture = tmpfile();
        if (stderr_capture == NULL) {
            if (stdout_capture != NULL) fclose(stdout_capture);
            return cyna_result_exit_status_err(CYNA_PROCESS_IO_ERROR);
        }
        stderr_fd = fileno(stderr_capture);
    }

    HANDLE process = NULL;
    CynaProcessError spawn_err = cyna_win_spawn(command, -1, stdout_fd, stderr_fd, &process);
    if (spawn_err != CYNA_PROCESS_IO_ERROR) {
        if (stdout_capture != NULL) fclose(stdout_capture);
        if (stderr_capture != NULL) fclose(stderr_capture);
        return cyna_result_exit_status_err(spawn_err);
    }
    CynaExitStatus status;
    CynaProcessError wait_err = cyna_win_wait(process, &status);
    if (stdout_capture != NULL) fclose(stdout_capture);
    if (stderr_capture != NULL) fclose(stderr_capture);
    if (wait_err != CYNA_PROCESS_IO_ERROR) return cyna_result_exit_status_err(wait_err);
    return cyna_result_exit_status_ok(status);
}

CynaResultOutputProcessError cyna_std_process_output_raw(CynaCommandBuilder command) {
    if (command.stdin_mode == CYNA_STDIO_PIPED) return cyna_result_output_err(CYNA_PROCESS_INVALID_ARGUMENT);

    FILE *stdout_capture = tmpfile();
    FILE *stderr_capture = tmpfile();
    if (stdout_capture == NULL || stderr_capture == NULL) {
        if (stdout_capture != NULL) fclose(stdout_capture);
        if (stderr_capture != NULL) fclose(stderr_capture);
        return cyna_result_output_err(CYNA_PROCESS_IO_ERROR);
    }

    HANDLE process = NULL;
    CynaProcessError spawn_err = cyna_win_spawn(command, -1, fileno(stdout_capture), fileno(stderr_capture), &process);
    if (spawn_err != CYNA_PROCESS_IO_ERROR) {
        fclose(stdout_capture);
        fclose(stderr_capture);
        return cyna_result_output_err(spawn_err);
    }
    CynaExitStatus status;
    CynaProcessError wait_err = cyna_win_wait(process, &status);
    if (wait_err != CYNA_PROCESS_IO_ERROR) {
        fclose(stdout_capture);
        fclose(stderr_capture);
        return cyna_result_output_err(wait_err);
    }

    CynaResultStringProcessError stdout_text = cyna_read_tmpfile_string(stdout_capture);
    CynaResultStringProcessError stderr_text = cyna_read_tmpfile_string(stderr_capture);
    fclose(stdout_capture);
    fclose(stderr_capture);
    if (stdout_text.is_ok != 0) return cyna_result_output_err((CynaProcessError)stdout_text.err);
    if (stderr_text.is_ok != 0) {
        cyna_string_release(stdout_text.ok);
        return cyna_result_output_err((CynaProcessError)stderr_text.err);
    }
    return cyna_result_output_ok((CynaOutput){
        .status = status,
        .stdout_text = stdout_text.ok,
        .stderr_text = stderr_text.ok,
    });
}
#else
CynaResultExitStatusProcessError cyna_std_process_run_raw(CynaCommandBuilder command) {
    if (command.stdin_mode == CYNA_STDIO_PIPED) return cyna_result_exit_status_err(CYNA_PROCESS_INVALID_ARGUMENT);

    FILE *stdout_capture = NULL;
    FILE *stderr_capture = NULL;
    int stdout_fd = -1;
    int stderr_fd = -1;

    if (command.stdout_mode == CYNA_STDIO_PIPED) {
        stdout_capture = tmpfile();
        if (stdout_capture == NULL) return cyna_result_exit_status_err(CYNA_PROCESS_IO_ERROR);
        stdout_fd = fileno(stdout_capture);
    }
    if (command.stderr_mode == CYNA_STDIO_PIPED) {
        stderr_capture = tmpfile();
        if (stderr_capture == NULL) {
            if (stdout_capture != NULL) fclose(stdout_capture);
            return cyna_result_exit_status_err(CYNA_PROCESS_IO_ERROR);
        }
        stderr_fd = fileno(stderr_capture);
    }

    int exec_error_pipe[2];
    if (pipe(exec_error_pipe) != 0) {
        if (stdout_capture != NULL) fclose(stdout_capture);
        if (stderr_capture != NULL) fclose(stderr_capture);
        return cyna_result_exit_status_err(CYNA_PROCESS_IO_ERROR);
    }
    (void)fcntl(exec_error_pipe[1], F_SETFD, FD_CLOEXEC);

    pid_t pid = fork();
    if (pid < 0) {
        close(exec_error_pipe[0]);
        close(exec_error_pipe[1]);
        if (stdout_capture != NULL) fclose(stdout_capture);
        if (stderr_capture != NULL) fclose(stderr_capture);
        return cyna_result_exit_status_err(CYNA_PROCESS_SPAWN_FAILED);
    }

    if (pid == 0) {
        close(exec_error_pipe[0]);
        int child_err = cyna_apply_child_process(command, -1, stdout_fd, stderr_fd, exec_error_pipe[1]);
        (void)write(exec_error_pipe[1], &child_err, sizeof(child_err));
        _exit(127);
    }

    close(exec_error_pipe[1]);
    CynaExitStatus status;
    CynaProcessError err = cyna_wait_for_child(pid, exec_error_pipe[0], &status);
    close(exec_error_pipe[0]);
    if (stdout_capture != NULL) fclose(stdout_capture);
    if (stderr_capture != NULL) fclose(stderr_capture);
    if (err != CYNA_PROCESS_IO_ERROR) return cyna_result_exit_status_err(err);
    return cyna_result_exit_status_ok(status);
}

CynaResultOutputProcessError cyna_std_process_output_raw(CynaCommandBuilder command) {
    if (command.stdin_mode == CYNA_STDIO_PIPED) return cyna_result_output_err(CYNA_PROCESS_INVALID_ARGUMENT);

    FILE *stdout_capture = tmpfile();
    FILE *stderr_capture = tmpfile();
    if (stdout_capture == NULL || stderr_capture == NULL) {
        if (stdout_capture != NULL) fclose(stdout_capture);
        if (stderr_capture != NULL) fclose(stderr_capture);
        return cyna_result_output_err(CYNA_PROCESS_IO_ERROR);
    }

    int exec_error_pipe[2];
    if (pipe(exec_error_pipe) != 0) {
        fclose(stdout_capture);
        fclose(stderr_capture);
        return cyna_result_output_err(CYNA_PROCESS_IO_ERROR);
    }
    (void)fcntl(exec_error_pipe[1], F_SETFD, FD_CLOEXEC);

    pid_t pid = fork();
    if (pid < 0) {
        close(exec_error_pipe[0]);
        close(exec_error_pipe[1]);
        fclose(stdout_capture);
        fclose(stderr_capture);
        return cyna_result_output_err(CYNA_PROCESS_SPAWN_FAILED);
    }

    if (pid == 0) {
        close(exec_error_pipe[0]);
        int child_err = cyna_apply_child_process(command, -1, fileno(stdout_capture), fileno(stderr_capture), exec_error_pipe[1]);
        (void)write(exec_error_pipe[1], &child_err, sizeof(child_err));
        _exit(127);
    }

    close(exec_error_pipe[1]);
    CynaExitStatus status;
    CynaProcessError err = cyna_wait_for_child(pid, exec_error_pipe[0], &status);
    close(exec_error_pipe[0]);
    if (err != CYNA_PROCESS_IO_ERROR) {
        fclose(stdout_capture);
        fclose(stderr_capture);
        return cyna_result_output_err(err);
    }

    CynaResultStringProcessError stdout_text = cyna_read_tmpfile_string(stdout_capture);
    CynaResultStringProcessError stderr_text = cyna_read_tmpfile_string(stderr_capture);
    fclose(stdout_capture);
    fclose(stderr_capture);
    if (stdout_text.is_ok != 0) return cyna_result_output_err((CynaProcessError)stdout_text.err);
    if (stderr_text.is_ok != 0) {
        cyna_string_release(stdout_text.ok);
        return cyna_result_output_err((CynaProcessError)stderr_text.err);
    }

    return cyna_result_output_ok((CynaOutput){
        .status = status,
        .stdout_text = stdout_text.ok,
        .stderr_text = stderr_text.ok,
    });
}
#endif

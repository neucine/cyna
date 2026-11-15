#include "../../../src/runtime/cyna.h"
#include <string.h>

typedef struct {
    CynaString *ptr;
    int64_t len;
} CynaStringSlice;

typedef struct {
    uint8_t is_some;
    CynaString value;
} CynaOptionalString;

static uint8_t cyna_path_is_separator(char ch) {
#ifdef _WIN32
    return ch == '/' || ch == '\\';
#else
    return ch == '/';
#endif
}

static uint8_t cyna_path_is_absolute_bytes(const char *ptr, int64_t len) {
    if (len > 0 && cyna_path_is_separator(ptr[0])) return 1;
#ifdef _WIN32
    if (len >= 3 && ((ptr[0] >= 'A' && ptr[0] <= 'Z') || (ptr[0] >= 'a' && ptr[0] <= 'z')) && ptr[1] == ':' && cyna_path_is_separator(ptr[2])) return 1;
#endif
    return 0;
}

static int64_t cyna_path_root_length(const char *ptr, int64_t len) {
#ifdef _WIN32
    if (len >= 3 && ((ptr[0] >= 'A' && ptr[0] <= 'Z') || (ptr[0] >= 'a' && ptr[0] <= 'z')) && ptr[1] == ':' && cyna_path_is_separator(ptr[2])) return 3;
#endif
    return len > 0 && cyna_path_is_separator(ptr[0]) ? 1 : 0;
}

static CynaString cyna_path_copy(const char *ptr, int64_t len) {
    CynaString out = cyna_runtime_string_new_uninit(len);
    if (len != 0) memcpy((char *)out.ptr, ptr, (size_t)len);
    return out;
}

static int64_t cyna_trim_trailing_slashes(const char *ptr, int64_t len) {
    const int64_t root_len = cyna_path_root_length(ptr, len);
    while (len > root_len && cyna_path_is_separator(ptr[len - 1])) len -= 1;
    return len;
}

static int64_t cyna_skip_leading_slashes(const char *ptr, int64_t len) {
    int64_t index = 0;
    while (index < len && cyna_path_is_separator(ptr[index])) index += 1;
    return index;
}

static int64_t cyna_basename_start(const char *ptr, int64_t len) {
    int64_t start = len;
    while (start > 0 && !cyna_path_is_separator(ptr[start - 1])) start -= 1;
    return start;
}

static int64_t cyna_extension_dot(const char *ptr, int64_t start, int64_t len) {
    int64_t dot = len;
    while (dot > start && ptr[dot - 1] != '.') dot -= 1;
    if (dot <= start) return -1;
    dot -= 1;
    if (dot == start) return -1;
    if (dot == len - 1) return -1;
    return dot;
}

uint8_t cyna_std_path_is_absolute(CynaString path) {
    const int64_t len = cyna_string_logical_len(path);
    const uint8_t result = cyna_path_is_absolute_bytes(path.ptr, len);
    cyna_string_release(path);
    return result;
}

CynaString cyna_std_path_basename(CynaString path) {
    const char *ptr = path.ptr;
    int64_t len = cyna_trim_trailing_slashes(ptr, cyna_string_logical_len(path));
    if (len == 0) {
        cyna_string_release(path);
        return cyna_path_copy("", 0);
    }
    if (len == cyna_path_root_length(ptr, len) && len > 0) {
        CynaString out = cyna_path_copy(ptr, len);
        cyna_string_release(path);
        return out;
    }

    int64_t start = cyna_basename_start(ptr, len);
    CynaString out = cyna_path_copy(ptr + start, len - start);
    cyna_string_release(path);
    return out;
}

CynaString cyna_std_path_dirname(CynaString path) {
    const char *ptr = path.ptr;
    int64_t len = cyna_trim_trailing_slashes(ptr, cyna_string_logical_len(path));
    if (len == 0) {
        cyna_string_release(path);
        return cyna_path_copy(".", 1);
    }
    if (len == cyna_path_root_length(ptr, len) && len > 0) {
        CynaString out = cyna_path_copy(ptr, len);
        cyna_string_release(path);
        return out;
    }

    int64_t slash = len;
    while (slash > 0 && !cyna_path_is_separator(ptr[slash - 1])) slash -= 1;
    if (slash == 0) {
        cyna_string_release(path);
        return cyna_path_copy(".", 1);
    }

    int64_t dir_len = cyna_trim_trailing_slashes(ptr, slash - 1);
    const int64_t root_len = cyna_path_root_length(ptr, len);
    if (dir_len < root_len) dir_len = root_len;
    if (dir_len == 0 && cyna_path_is_separator(ptr[0])) dir_len = 1;
    if (dir_len == 0) {
        cyna_string_release(path);
        return cyna_path_copy(".", 1);
    }
    CynaString out = cyna_path_copy(ptr, dir_len);
    cyna_string_release(path);
    return out;
}

CynaOptionalString cyna_std_path_extension(CynaString path) {
    const char *ptr = path.ptr;
    const int64_t len = cyna_trim_trailing_slashes(ptr, cyna_string_logical_len(path));
    const int64_t start = cyna_basename_start(ptr, len);
    const int64_t dot = cyna_extension_dot(ptr, start, len);
    if (dot < 0) {
        cyna_string_release(path);
        return (CynaOptionalString){ .is_some = 0, .value = cyna_string_make_static("", 0) };
    }

    CynaString out = cyna_path_copy(ptr + dot + 1, len - dot - 1);
    cyna_string_release(path);
    return (CynaOptionalString){ .is_some = 1, .value = out };
}

CynaString cyna_std_path_stem(CynaString path) {
    const char *ptr = path.ptr;
    const int64_t len = cyna_trim_trailing_slashes(ptr, cyna_string_logical_len(path));
    if (len == 0) {
        cyna_string_release(path);
        return cyna_path_copy("", 0);
    }
    if (len == cyna_path_root_length(ptr, len) && len > 0) {
        CynaString out = cyna_path_copy(ptr, len);
        cyna_string_release(path);
        return out;
    }

    const int64_t start = cyna_basename_start(ptr, len);
    int64_t end = len;
    const int64_t dot = cyna_extension_dot(ptr, start, len);
    if (dot >= 0) end = dot;

    CynaString out = cyna_path_copy(ptr + start, end - start);
    cyna_string_release(path);
    return out;
}

CynaString cyna_std_path_join(CynaStringSlice parts) {
    int64_t start = -1;
    for (int64_t i = 0; i < parts.len; i += 1) {
        CynaString part = parts.ptr[i];
        const int64_t len = cyna_string_logical_len(part);
        if (len == 0) continue;
        if (cyna_path_is_absolute_bytes(part.ptr, len) || start < 0) start = i;
    }
    if (start < 0) return cyna_path_copy("", 0);

    int64_t total = 0;
    uint8_t have_output = 0;
    uint8_t output_ends_slash = 0;
    for (int64_t i = start; i < parts.len; i += 1) {
        CynaString part = parts.ptr[i];
        int64_t part_len = cyna_string_logical_len(part);
        if (part_len == 0) continue;
        int64_t part_start = 0;
        if (i != start) part_start = cyna_skip_leading_slashes(part.ptr, part_len);
        part_len -= part_start;
        if (part_len == 0) continue;
        part_len = cyna_trim_trailing_slashes(part.ptr + part_start, part_len);

        if (have_output && !output_ends_slash) total += 1;
        total += part_len;
        have_output = 1;
        output_ends_slash = cyna_path_is_separator(part.ptr[part_start + part_len - 1]);
    }
    if (!have_output) return cyna_path_copy("", 0);

    CynaString out = cyna_runtime_string_new_uninit(total);
    char *dst = (char *)out.ptr;
    int64_t written = 0;
    output_ends_slash = 0;
    have_output = 0;
    for (int64_t i = start; i < parts.len; i += 1) {
        CynaString part = parts.ptr[i];
        int64_t part_len = cyna_string_logical_len(part);
        if (part_len == 0) continue;
        int64_t part_start = 0;
        if (i != start) part_start = cyna_skip_leading_slashes(part.ptr, part_len);
        part_len -= part_start;
        if (part_len == 0) continue;
        part_len = cyna_trim_trailing_slashes(part.ptr + part_start, part_len);

        if (have_output && !output_ends_slash) dst[written++] = '/';
        memcpy(dst + written, part.ptr + part_start, (size_t)part_len);
        written += part_len;
        have_output = 1;
        output_ends_slash = cyna_path_is_separator(dst[written - 1]);
    }
    return out;
}

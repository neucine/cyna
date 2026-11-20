#ifndef _WIN32
#define _DEFAULT_SOURCE 1
#endif
#include "../../../src/runtime/cyna.h"
#ifndef _WIN32
#include <dirent.h>
#include <unistd.h>
#else
#include <direct.h>
#include <fcntl.h>
#include <io.h>
#endif
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

typedef enum {
    CYNA_FS_NOT_FOUND = 0,
    CYNA_FS_PERMISSION_DENIED = 1,
    CYNA_FS_ALREADY_EXISTS = 2,
    CYNA_FS_INVALID_PATH = 3,
    CYNA_FS_IO_ERROR = 4,
} CynaFsError;

typedef struct {
    CynaString name;
    int32_t kind;
} CynaRawDirEntry;

typedef struct {
    uint8_t is_ok;
    CynaString ok;
    int32_t err;
} CynaResultStringFsError;

typedef struct {
    uint8_t is_ok;
    uint8_t ok;
    int32_t err;
} CynaResultBoolFsError;

typedef struct {
    uint8_t is_ok;
    uint8_t ok;
    int32_t err;
} CynaResultVoidFsError;

typedef struct {
    uint8_t is_ok;
    void *ok;
    int32_t err;
} CynaResultListFsError;

typedef struct {
    uint8_t is_ok;
    size_t ok;
    int32_t err;
} CynaResultHandleFsError;

typedef struct {
    uint8_t is_ok;
    size_t ok;
    int32_t err;
} CynaResultSizeIoError;

typedef struct {
    uint8_t is_ok;
    uint8_t ok;
    int32_t err;
} CynaResultVoidIoError;

typedef struct {
    uint8_t is_ok;
    void *ok;
    int32_t err;
} CynaResultBytesFsError;

typedef struct {
    uint8_t is_some;
    CynaRawDirEntry value;
} CynaOptionalRawDirEntry;

typedef struct {
    uint8_t is_ok;
    CynaOptionalRawDirEntry ok;
    int32_t err;
} CynaResultOptionalRawDirEntryFsError;

static CynaFsError cyna_map_fs_errno(int err) {
    switch (err) {
        case ENOENT: return CYNA_FS_NOT_FOUND;
        case EACCES:
        case EPERM: return CYNA_FS_PERMISSION_DENIED;
        case EEXIST: return CYNA_FS_ALREADY_EXISTS;
        case ENAMETOOLONG:
        case ENOTDIR:
        case EINVAL: return CYNA_FS_INVALID_PATH;
        default: return CYNA_FS_IO_ERROR;
    }
}

static char *cyna_path_buf(CynaString path) {
    const int64_t len = cyna_string_logical_len(path);
    char *buf = (char *)cyna_runtime_tracked_alloc_site((size_t)len + 1u, __FILE__, __LINE__, "std.fs.path_buf");
    if (buf == NULL) return NULL;
    memcpy(buf, path.ptr, (size_t)len);
    buf[len] = '\0';
    return buf;
}

static CynaString cyna_copy_bytes_as_string(const char *ptr, int64_t len) {
    CynaString value = cyna_runtime_string_new_uninit(len);
    if (len != 0) memcpy((char *)value.ptr, ptr, (size_t)len);
    return value;
}

static CynaDense *cyna_copy_bytes_as_dense(const unsigned char *ptr, int64_t len) {
    CynaDense *dense = (CynaDense *)cyna_runtime_tracked_alloc_site(sizeof(CynaDense), __FILE__, __LINE__, "std.fs.bytes.dense");
    if (dense == NULL) abort();
    dense->elem_desc = &cyna_desc_u8;
    dense->len = len;
    dense->cap = len;
    dense->data = NULL;
    if (len != 0) {
        dense->data = (unsigned char *)cyna_runtime_tracked_alloc_site((size_t)len, __FILE__, __LINE__, "std.fs.bytes.data");
        if (dense->data == NULL) abort();
        memcpy(dense->data, ptr, (size_t)len);
    }
    return dense;
}

static void cyna_dense_reserve_bytes(CynaDense *dense, int64_t want) {
    if (dense->cap >= want) return;
    int64_t next = dense->cap == 0 ? 4 : dense->cap;
    const int64_t elem_size = dense->elem_desc->size;
    while (next < want) next *= 2;
    dense->data = (unsigned char *)cyna_runtime_tracked_realloc_site(dense->data, (size_t)(next * elem_size), __FILE__, __LINE__, "std.fs.dense.grow");
    if (dense->data == NULL) abort();
    dense->cap = next;
}

static CynaResultStringFsError cyna_std_fs_result_string_ok(CynaString value) {
    CynaResultStringFsError out;
    out.is_ok = 0;
    out.ok = value;
    out.err = CYNA_FS_NOT_FOUND;
    return out;
}

static CynaResultStringFsError cyna_std_fs_result_string_err(CynaFsError err) {
    CynaResultStringFsError out;
    out.is_ok = 1;
    out.ok.ptr = NULL;
    out.ok.len = 0;
    out.err = (int32_t)err;
    return out;
}

static CynaResultBoolFsError cyna_std_fs_result_bool_ok(uint8_t value) {
    CynaResultBoolFsError out;
    out.is_ok = 0;
    out.ok = value;
    out.err = CYNA_FS_NOT_FOUND;
    return out;
}

static CynaResultBoolFsError cyna_std_fs_result_bool_err(CynaFsError err) {
    CynaResultBoolFsError out;
    out.is_ok = 1;
    out.ok = 0;
    out.err = (int32_t)err;
    return out;
}

static CynaResultVoidFsError cyna_std_fs_result_void_ok(void) {
    CynaResultVoidFsError out;
    out.is_ok = 0;
    out.ok = 0;
    out.err = CYNA_FS_NOT_FOUND;
    return out;
}

static CynaResultVoidFsError cyna_std_fs_result_void_err(CynaFsError err) {
    CynaResultVoidFsError out;
    out.is_ok = 1;
    out.ok = 0;
    out.err = (int32_t)err;
    return out;
}

static CynaResultListFsError cyna_std_fs_result_list_ok(void *value) {
    CynaResultListFsError out;
    out.is_ok = 0;
    out.ok = value;
    out.err = CYNA_FS_NOT_FOUND;
    return out;
}

static CynaResultListFsError cyna_std_fs_result_list_err(CynaFsError err) {
    CynaResultListFsError out;
    out.is_ok = 1;
    out.ok = NULL;
    out.err = (int32_t)err;
    return out;
}

static CynaResultBytesFsError cyna_std_fs_result_bytes_ok(void *value) {
    CynaResultBytesFsError out;
    out.is_ok = 0;
    out.ok = value;
    out.err = CYNA_FS_NOT_FOUND;
    return out;
}

static CynaResultBytesFsError cyna_std_fs_result_bytes_err(CynaFsError err) {
    CynaResultBytesFsError out;
    out.is_ok = 1;
    out.ok = NULL;
    out.err = (int32_t)err;
    return out;
}

static CynaResultHandleFsError cyna_std_fs_result_handle_ok(size_t value) {
    CynaResultHandleFsError out;
    out.is_ok = 0;
    out.ok = value;
    out.err = CYNA_FS_NOT_FOUND;
    return out;
}

static CynaResultHandleFsError cyna_std_fs_result_handle_err(CynaFsError err) {
    CynaResultHandleFsError out;
    out.is_ok = 1;
    out.ok = 0;
    out.err = (int32_t)err;
    return out;
}

static CynaResultSizeIoError cyna_std_fs_result_size_io_ok(size_t value) {
    CynaResultSizeIoError out;
    out.is_ok = 0;
    out.ok = value;
    out.err = 0;
    return out;
}

static CynaResultSizeIoError cyna_std_fs_result_size_io_err(int32_t error) {
    CynaResultSizeIoError out;
    out.is_ok = 1;
    out.ok = 0;
    out.err = error;
    return out;
}

static CynaResultVoidIoError cyna_std_fs_result_void_io(int failed) {
    CynaResultVoidIoError out;
    out.is_ok = (uint8_t)(failed != 0);
    out.ok = 0;
    out.err = failed != 0 ? 1 : 0; // IoError.write_failed
    return out;
}

size_t cyna_std_fs_file_stdin_raw(void) { return (size_t)(uintptr_t)stdin; }
size_t cyna_std_fs_file_stdout_raw(void) { return (size_t)(uintptr_t)stdout; }
size_t cyna_std_fs_file_stderr_raw(void) { return (size_t)(uintptr_t)stderr; }

static int cyna_std_fs_prepare_binary_stream(FILE *file) {
#ifdef _WIN32
    if (file == stdin || file == stdout || file == stderr) {
        return _setmode(_fileno(file), _O_BINARY) != -1;
    }
#else
    (void)file;
#endif
    return 1;
}

static CynaResultHandleFsError cyna_std_fs_file_open(CynaString path, const char *mode) {
    const int64_t length = cyna_string_logical_len(path);
    if (length != 0 && memchr(path.ptr, 0, (size_t)length) != NULL) {
        cyna_string_release(path);
        return cyna_std_fs_result_handle_err(CYNA_FS_INVALID_PATH);
    }
    char *path_buf = cyna_path_buf(path);
    cyna_string_release(path);
    if (path_buf == NULL) return cyna_std_fs_result_handle_err(CYNA_FS_IO_ERROR);
    FILE *file = fopen(path_buf, mode);
    const int saved_errno = errno;
    cyna_runtime_tracked_free(path_buf);
    if (file == NULL) return cyna_std_fs_result_handle_err(cyna_map_fs_errno(saved_errno));
    return cyna_std_fs_result_handle_ok((size_t)(uintptr_t)file);
}

CynaResultHandleFsError cyna_std_fs_file_open_read_raw(CynaString path) {
    return cyna_std_fs_file_open(path, "rb");
}

CynaResultHandleFsError cyna_std_fs_file_open_write_raw(CynaString path) {
    return cyna_std_fs_file_open(path, "wb");
}

CynaResultSizeIoError cyna_std_fs_file_read_raw(size_t handle, CynaBytes dest) {
    FILE *file = (FILE *)(uintptr_t)handle;
    if (file == NULL || dest.len < 0 || (dest.len != 0 && dest.ptr == NULL)) {
        return cyna_std_fs_result_size_io_err(3); // IoError.invalid_count
    }
    if (!cyna_std_fs_prepare_binary_stream(file)) return cyna_std_fs_result_size_io_err(0);
    if (dest.len == 0) return cyna_std_fs_result_size_io_ok(0);
    const size_t count = fread(dest.ptr, 1, (size_t)dest.len, file);
    if (count == 0 && ferror(file)) return cyna_std_fs_result_size_io_err(0); // IoError.read_failed
    return cyna_std_fs_result_size_io_ok(count);
}

CynaResultSizeIoError cyna_std_fs_file_write_raw(size_t handle, CynaBytes data) {
    FILE *file = (FILE *)(uintptr_t)handle;
    if (file == NULL || data.len < 0 || (data.len != 0 && data.ptr == NULL)) {
        return cyna_std_fs_result_size_io_err(3); // IoError.invalid_count
    }
    if (!cyna_std_fs_prepare_binary_stream(file)) return cyna_std_fs_result_size_io_err(1);
    if (data.len == 0) return cyna_std_fs_result_size_io_ok(0);
    const size_t count = fwrite(data.ptr, 1, (size_t)data.len, file);
    if (count == 0 && ferror(file)) return cyna_std_fs_result_size_io_err(1); // IoError.write_failed
    return cyna_std_fs_result_size_io_ok(count);
}

CynaResultVoidIoError cyna_std_fs_file_flush_raw(size_t handle) {
    FILE *file = (FILE *)(uintptr_t)handle;
    if (file == NULL) return cyna_std_fs_result_void_io(1);
    return cyna_std_fs_result_void_io(fflush(file));
}

CynaResultVoidFsError cyna_std_fs_file_close_raw(size_t handle) {
    FILE *file = (FILE *)(uintptr_t)handle;
    if (file == NULL) return cyna_std_fs_result_void_err(CYNA_FS_IO_ERROR);
    if (fclose(file) != 0) return cyna_std_fs_result_void_err(CYNA_FS_IO_ERROR);
    return cyna_std_fs_result_void_ok();
}

static CynaResultOptionalRawDirEntryFsError cyna_std_fs_result_optional_raw_dir_entry_ok(CynaOptionalRawDirEntry value) {
    CynaResultOptionalRawDirEntryFsError out;
    out.is_ok = 0;
    out.ok = value;
    out.err = CYNA_FS_NOT_FOUND;
    return out;
}

static CynaResultOptionalRawDirEntryFsError cyna_std_fs_result_optional_raw_dir_entry_err(CynaFsError err) {
    CynaResultOptionalRawDirEntryFsError out;
    out.is_ok = 1;
    out.ok.is_some = 0;
    out.ok.value.name.ptr = NULL;
    out.ok.value.name.len = 0;
    out.ok.value.kind = 0;
    out.err = (int32_t)err;
    return out;
}

CynaResultStringFsError cyna_std_fs_read_file(CynaString path) {
    char *path_buf = cyna_path_buf(path);
    cyna_string_release(path);
    if (path_buf == NULL) return cyna_std_fs_result_string_err(CYNA_FS_IO_ERROR);

    FILE *file = fopen(path_buf, "rb");
    cyna_runtime_tracked_free(path_buf);
    if (file == NULL) return cyna_std_fs_result_string_err(cyna_map_fs_errno(errno));

    if (fseek(file, 0, SEEK_END) != 0) {
        fclose(file);
        return cyna_std_fs_result_string_err(CYNA_FS_IO_ERROR);
    }
    long size_long = ftell(file);
    if (size_long < 0) {
        fclose(file);
        return cyna_std_fs_result_string_err(CYNA_FS_IO_ERROR);
    }
    if (fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        return cyna_std_fs_result_string_err(CYNA_FS_IO_ERROR);
    }

    int64_t size = (int64_t)size_long;
    CynaString value = cyna_runtime_string_new_uninit(size);
    if (size != 0) {
        size_t read = fread((char *)value.ptr, 1, (size_t)size, file);
        if (read != (size_t)size) {
            cyna_string_release(value);
            fclose(file);
            return cyna_std_fs_result_string_err(CYNA_FS_IO_ERROR);
        }
    }
    fclose(file);
    return cyna_std_fs_result_string_ok(value);
}

CynaResultBytesFsError cyna_std_fs_read_bytes(CynaString path) {
    char *path_buf = cyna_path_buf(path);
    cyna_string_release(path);
    if (path_buf == NULL) return cyna_std_fs_result_bytes_err(CYNA_FS_IO_ERROR);

    FILE *file = fopen(path_buf, "rb");
    cyna_runtime_tracked_free(path_buf);
    if (file == NULL) return cyna_std_fs_result_bytes_err(cyna_map_fs_errno(errno));

    if (fseek(file, 0, SEEK_END) != 0) {
        fclose(file);
        return cyna_std_fs_result_bytes_err(CYNA_FS_IO_ERROR);
    }
    long size_long = ftell(file);
    if (size_long < 0) {
        fclose(file);
        return cyna_std_fs_result_bytes_err(CYNA_FS_IO_ERROR);
    }
    if (fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        return cyna_std_fs_result_bytes_err(CYNA_FS_IO_ERROR);
    }

    int64_t size = (int64_t)size_long;
    unsigned char *data = NULL;
    if (size != 0) {
        data = (unsigned char *)cyna_runtime_tracked_alloc_site((size_t)size, __FILE__, __LINE__, "std.fs.read_file.data");
        if (data == NULL) {
            fclose(file);
            return cyna_std_fs_result_bytes_err(CYNA_FS_IO_ERROR);
        }
        if (fread(data, 1, (size_t)size, file) != (size_t)size) {
            cyna_runtime_tracked_free(data);
            fclose(file);
            return cyna_std_fs_result_bytes_err(CYNA_FS_IO_ERROR);
        }
    }
    fclose(file);
    CynaDense *list = cyna_copy_bytes_as_dense(data, size);
    cyna_runtime_tracked_free(data);
    return cyna_std_fs_result_bytes_ok(list);
}

CynaResultVoidFsError cyna_std_fs_write_bytes_raw(CynaString path, CynaBytes data) {
    char *path_buf = cyna_path_buf(path);
    cyna_string_release(path);
    if (path_buf == NULL) return cyna_std_fs_result_void_err(CYNA_FS_IO_ERROR);

    FILE *file = fopen(path_buf, "wb");
    cyna_runtime_tracked_free(path_buf);
    if (file == NULL) return cyna_std_fs_result_void_err(cyna_map_fs_errno(errno));
    if (data.len != 0) {
        if (fwrite(data.ptr, 1, (size_t)data.len, file) != (size_t)data.len) {
            fclose(file);
            return cyna_std_fs_result_void_err(CYNA_FS_IO_ERROR);
        }
    }
    if (fclose(file) != 0) return cyna_std_fs_result_void_err(CYNA_FS_IO_ERROR);
    return cyna_std_fs_result_void_ok();
}

CynaResultBoolFsError cyna_std_fs_exists(CynaString path) {
    char *path_buf = cyna_path_buf(path);
    cyna_string_release(path);
    if (path_buf == NULL) return cyna_std_fs_result_bool_err(CYNA_FS_IO_ERROR);
#ifdef _WIN32
    int rc = _access(path_buf, 0);
#else
    int rc = access(path_buf, F_OK);
#endif
    int err = errno;
    cyna_runtime_tracked_free(path_buf);
    if (rc == 0) return cyna_std_fs_result_bool_ok(1);
    if (err == ENOENT) return cyna_std_fs_result_bool_ok(0);
    return cyna_std_fs_result_bool_err(cyna_map_fs_errno(err));
}

CynaResultVoidFsError cyna_std_fs_create_dir(CynaString path) {
    char *path_buf = cyna_path_buf(path);
    cyna_string_release(path);
    if (path_buf == NULL) return cyna_std_fs_result_void_err(CYNA_FS_IO_ERROR);
#ifdef _WIN32
    int rc = _mkdir(path_buf);
#else
    int rc = mkdir(path_buf, 0777);
#endif
    int err = errno;
    cyna_runtime_tracked_free(path_buf);
    if (rc == 0) return cyna_std_fs_result_void_ok();
    return cyna_std_fs_result_void_err(cyna_map_fs_errno(err));
}

#ifdef _WIN32
typedef struct {
    intptr_t search;
    struct _finddata_t entry;
    uint8_t pending;
} CynaWindowsDir;
#endif

CynaResultHandleFsError cyna_std_fs_open_dir(CynaString path) {
    char *path_buf = cyna_path_buf(path);
    cyna_string_release(path);
    if (path_buf == NULL) return cyna_std_fs_result_handle_err(CYNA_FS_IO_ERROR);

#ifdef _WIN32
    struct _stat directory_info;
    if (_stat(path_buf, &directory_info) != 0) {
        int err = errno;
        cyna_runtime_tracked_free(path_buf);
        return cyna_std_fs_result_handle_err(cyna_map_fs_errno(err));
    }
    if (!(directory_info.st_mode & _S_IFDIR)) {
        cyna_runtime_tracked_free(path_buf);
        return cyna_std_fs_result_handle_err(CYNA_FS_INVALID_PATH);
    }
    size_t len = strlen(path_buf);
    char *pattern = (char *)malloc(len + 3);
    if (pattern == NULL) {
        cyna_runtime_tracked_free(path_buf);
        return cyna_std_fs_result_handle_err(CYNA_FS_IO_ERROR);
    }
    memcpy(pattern, path_buf, len);
    if (len && path_buf[len - 1] != '/' && path_buf[len - 1] != '\\') pattern[len++] = '\\';
    pattern[len++] = '*';
    pattern[len] = '\0';
    CynaWindowsDir *handle = (CynaWindowsDir *)malloc(sizeof(CynaWindowsDir));
    if (handle == NULL) {
        free(pattern);
        cyna_runtime_tracked_free(path_buf);
        return cyna_std_fs_result_handle_err(CYNA_FS_IO_ERROR);
    }
    handle->search = _findfirst(pattern, &handle->entry);
    int err = errno;
    free(pattern);
    cyna_runtime_tracked_free(path_buf);
    if (handle->search == -1 && err != ENOENT) {
        free(handle);
        return cyna_std_fs_result_handle_err(cyna_map_fs_errno(err));
    }
    handle->pending = handle->search != -1;
    return cyna_std_fs_result_handle_ok((size_t)handle);
#else
    DIR *dir = opendir(path_buf);
    int err = errno;
    cyna_runtime_tracked_free(path_buf);
    if (dir == NULL) {
        return cyna_std_fs_result_handle_err(cyna_map_fs_errno(err));
    }
    return cyna_std_fs_result_handle_ok((size_t)dir);
#endif
}

CynaResultOptionalRawDirEntryFsError cyna_std_fs_read_dir_next(size_t handle) {
#ifdef _WIN32
    CynaWindowsDir *win_dir = (CynaWindowsDir *)handle;
    if (win_dir == NULL) return cyna_std_fs_result_optional_raw_dir_entry_err(CYNA_FS_IO_ERROR);
    if (win_dir->search == -1) {
        return cyna_std_fs_result_optional_raw_dir_entry_ok((CynaOptionalRawDirEntry){
            .is_some = 0,
            .value = { .name = { .ptr = NULL, .len = 0 }, .kind = 0 },
        });
    }
    if (win_dir->pending) {
        win_dir->pending = 0;
    } else if (_findnext(win_dir->search, &win_dir->entry) != 0) {
        if (errno != ENOENT) return cyna_std_fs_result_optional_raw_dir_entry_err(cyna_map_fs_errno(errno));
        return cyna_std_fs_result_optional_raw_dir_entry_ok((CynaOptionalRawDirEntry){
            .is_some = 0,
            .value = { .name = { .ptr = NULL, .len = 0 }, .kind = 0 },
        });
    }
    return cyna_std_fs_result_optional_raw_dir_entry_ok((CynaOptionalRawDirEntry){
        .is_some = 1,
        .value = {
            .name = cyna_copy_bytes_as_string(win_dir->entry.name, (int64_t)strlen(win_dir->entry.name)),
            .kind = (win_dir->entry.attrib & _A_SUBDIR) ? 1 : 0,
        },
    });
#else
    DIR *dir = (DIR *)handle;
    errno = 0;
    struct dirent *entry = readdir(dir);
    if (entry == NULL) {
        if (errno != 0) return cyna_std_fs_result_optional_raw_dir_entry_err(cyna_map_fs_errno(errno));
        return cyna_std_fs_result_optional_raw_dir_entry_ok((CynaOptionalRawDirEntry){
            .is_some = 0,
            .value = { .name = { .ptr = NULL, .len = 0 }, .kind = 0 },
        });
    }
    return cyna_std_fs_result_optional_raw_dir_entry_ok((CynaOptionalRawDirEntry){
        .is_some = 1,
        .value = {
            .name = cyna_copy_bytes_as_string(entry->d_name, (int64_t)strlen(entry->d_name)),
            .kind = entry->d_type == DT_DIR ? 1 : (entry->d_type == DT_REG ? 0 : 2),
        },
    });
#endif
}

void cyna_std_fs_close_dir(size_t handle) {
#ifdef _WIN32
    CynaWindowsDir *win_dir = (CynaWindowsDir *)handle;
    if (win_dir == NULL) return;
    if (win_dir->search != -1) _findclose(win_dir->search);
    free(win_dir);
#else
    DIR *dir = (DIR *)handle;
    if (dir == NULL) return;
    closedir(dir);
#endif
}

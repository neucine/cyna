import std.io;

pub enum FsError: i32 {
    not_found = 0,
    permission_denied,
    already_exists,
    invalid_path,
    io_error,
    invalid_mode,
}

pub enum DirEntryKind: i32 {
    file = 0,
    dir,
    other,
}

flags OpenMode: u8 {
    read = 1,
    write = 2,
    create = 4,
    truncate = 8,
    append = 16,
    create_new = 32,
}

pub struct DirEntry {
    pub name: string;
    pub kind: DirEntryKind;
}

@ownership.owned
pub c struct File {
    raw: c_size_t;

    // Closing consumes this handle, including when the final flush fails.
    pub fn close(self: File): void ! FsError {
        try file_close_raw(self.raw);
        return;
    }
}

impl File: io.Reader {
    fn read(self: &File, dest: []u8): usize ! io.IoError {
        return try file_read_raw(self.raw, dest);
    }
}

impl File: io.Writer {
    fn write(self: &File, data: []const u8): usize ! io.IoError {
        return try file_write_raw(self.raw, data);
    }
}

// Process-owned streams. These are borrowed handles and have no close method.
pub struct Stdin {
    raw: c_size_t;
}

pub struct Stdout {
    raw: c_size_t;

    pub fn flush(self: &Stdout): void ! io.IoError {
        try file_flush_raw(self.raw);
        return;
    }
}

pub struct Stderr {
    raw: c_size_t;

    pub fn flush(self: &Stderr): void ! io.IoError {
        try file_flush_raw(self.raw);
        return;
    }
}

impl Stdin: io.Reader {
    fn read(self: &Stdin, dest: []u8): usize ! io.IoError {
        return try file_read_raw(self.raw, dest);
    }
}

impl Stdout: io.Writer {
    fn write(self: &Stdout, data: []const u8): usize ! io.IoError {
        return try file_write_raw(self.raw, data);
    }
}

impl Stderr: io.Writer {
    fn write(self: &Stderr, data: []const u8): usize ! io.IoError {
        return try file_write_raw(self.raw, data);
    }
}

struct RawDirEntry {
    name: string;
    kind: DirEntryKind;
}

pub extern c fn read_file(path: string): string ! FsError;
pub extern c fn read_bytes(path: string): [:]u8 ! FsError;

pub fn exists(path: string): bool ! FsError {
    const status = exists_status(path);
    if status == 0 {
        return false;
    }
    if status == 1 {
        return true;
    }
    if status == 2 {
        throw FsError.permission_denied;
    }
    if status == 3 {
        throw FsError.already_exists;
    }
    if status == 4 {
        throw FsError.invalid_path;
    }
    throw FsError.io_error;
}

pub fn open(path: string, mode: OpenMode = OpenMode.read): File ! FsError {
    const raw = try file_open_raw(path, mode as u8);
    return File {
        raw: raw
    };
}

pub fn open_read(path: string): File ! FsError {
    return open(path, OpenMode.read);
}

// Creates or truncates a file. Call close to report any final flush failure.
pub fn open_write(path: string): File ! FsError {
    return open(path, OpenMode.write | OpenMode.create | OpenMode.truncate);
}

pub fn mkdir(path: string, recursive: bool = false): void ! FsError {
    try make_dir_raw(path, recursive);
    return;
}

pub fn rmdir(path: string, recursive: bool = false): void ! FsError {
    try remove_dir_raw(path, recursive);
    return;
}

pub fn stdin(): Stdin {
    return Stdin {
        raw: file_stdin_raw()
    };
}

pub fn stdout(): Stdout {
    return Stdout {
        raw: file_stdout_raw()
    };
}

pub fn stderr(): Stderr {
    return Stderr {
        raw: file_stderr_raw()
    };
}

extern {
    c fn exists_status(path: string): c_int;
    c fn file_open_raw(path: string, mode: u8): c_size_t ! FsError;
    c fn file_read_raw(handle: c_size_t, dest: []u8): usize ! io.IoError;
    c fn file_write_raw(handle: c_size_t, data: []const u8): usize ! io.IoError;
    c fn file_close_raw(handle: c_size_t): void ! FsError;
    c fn file_flush_raw(handle: c_size_t): void ! io.IoError;
    c fn file_stdin_raw(): c_size_t;
    c fn file_stdout_raw(): c_size_t;
    c fn file_stderr_raw(): c_size_t;
    c fn write_bytes_raw(path: string, data: []const u8): void ! FsError;
    c fn open_dir(path: string): c_size_t ! FsError;
    c fn read_dir_next(handle: c_size_t): ?RawDirEntry ! FsError;
    c fn close_dir(handle: c_size_t): void;
    c fn make_dir_raw(path: string, recursive: bool): void ! FsError;
    c fn remove_dir_raw(path: string, recursive: bool): void ! FsError;
}

pub fn write_file(path: string, data: string): void ! FsError {
    try write_bytes_raw(path, data.bytes());
    return;
}

pub fn write_bytes(path: string, data: []const u8): void ! FsError {
    try write_bytes_raw(path, data);
    return;
}

pub fn ls(path: string = "."): List<DirEntry>!FsError {
    const handle = try open_dir(path);
    defer close_dir(handle);
    var entries: List<DirEntry> = list<DirEntry>();
    var keep = true;
    while keep {
        const maybe_entry = try read_dir_next(handle);
        if maybe_entry is entry {
            if entry.name != "." and entry.name != ".." {
                entries.push(DirEntry {
                    name: entry.name,
                    kind: entry.kind
                });
            }
        } else {
            keep = false;
        }
    }
    return entries;
}

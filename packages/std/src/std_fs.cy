pub enum FsError: i32 {
    not_found = 0,
    permission_denied,
    already_exists,
    invalid_path,
    io_error,
}

pub enum DirEntryKind: i32 {
    file = 0,
    dir,
    other,
}

pub struct DirEntry {
    pub name: string;
    pub kind: DirEntryKind;
}

struct RawDirEntry {
    name: string;
    kind: DirEntryKind;
}

pub extern c fn read_file(path: string): string ! FsError;
pub extern c fn read_bytes(path: string): [:]u8 ! FsError;
pub extern c fn exists(path: string): bool ! FsError;
pub extern c fn create_dir(path: string): void ! FsError;

extern {
    c fn write_bytes_raw(path: string, data: []const u8): void ! FsError;
    c fn open_dir(path: string): c_size_t ! FsError;
    c fn read_dir_next(handle: c_size_t): ?RawDirEntry ! FsError;
    c fn close_dir(handle: c_size_t): void;
}

pub fn write_file(path: string, data: string): void ! FsError {
    try write_bytes_raw(path, data.bytes());
    return;
}

pub fn write_bytes(path: string, data: []const u8): void ! FsError {
    try write_bytes_raw(path, data);
    return;
}

pub fn read_dir(path: string): List<DirEntry>!FsError {
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

# std.fs

`std.fs` provides files, directories, and process-owned standard streams.

Available on macOS arm64, Linux x86-64, and Windows x86-64.

```cyna
import { DirEntry, File, FsError, OpenMode } from std.fs;
```

## Types

### `DirEntry`

| Field | Type | Meaning |
| --- | --- | --- |
| `name` | `string` | Entry name. |
| `kind` | `DirEntryKind` | Entry kind. |

`DirEntryKind` has the cases `file`, `dir`, and `other`.

### `File`

An owned file handle. It implements `std.io.Reader` and `std.io.Writer`.
The open mode controls what the operating system allows; reading from a
write-only file or writing to a read-only file fails through `std.io`.

### `Stdin`, `Stdout`, `Stderr`

Borrowed process-owned stream handles. They implement `std.io.Reader` or
`std.io.Writer`. Do not close them.

### `OpenMode`

`OpenMode` is a flags type. Combine members with `|`.

| Member | Value | Meaning |
| --- | --- | --- |
| `read` | 1 | Open for reading. |
| `write` | 2 | Open for writing. |
| `create` | 4 | Create the file when it does not exist. |
| `truncate` | 8 | Truncate an existing file. Requires `write`. |
| `append` | 16 | Write at the end of the file. Requires `write`. |
| `create_new` | 32 | Create a new file and fail if it already exists. Requires `write` and cannot be combined with `create` or `truncate`. |

At least one of `read` or `write` is required. `create`, `truncate`, `append`,
and `create_new` require `write`. Invalid combinations return
`FsError.invalid_mode`.

## Static functions

Call these through the module or an imported name.

| Function | Signature | Description |
| --- | --- | --- |
| `read_file` | `fn read_file(path: string): string ! FsError` | Reads a file as an owned string. |
| `read_bytes` | `fn read_bytes(path: string): [:]u8 ! FsError` | Reads a file as owned dense bytes. |
| `write_file` | `fn write_file(path: string, data: string): void ! FsError` | Replaces a file with string contents. |
| `write_bytes` | `fn write_bytes(path: string, data: []const u8): void ! FsError` | Replaces a file with byte-slice contents. |
| `exists` | `fn exists(path: string): bool ! FsError` | Reports whether a path exists. |
| `open` | `fn open(path: string, mode: OpenMode = OpenMode.read): File ! FsError` | Opens a file with the given mode. |
| `open_read` | `fn open_read(path: string): File ! FsError` | Opens a file for reading. |
| `open_write` | `fn open_write(path: string): File ! FsError` | Creates or truncates a file for writing. |
| `mkdir` | `fn mkdir(path: string, recursive: bool = false): void ! FsError` | Creates a directory. With `recursive = true`, creates missing parents and succeeds when the final directory exists. |
| `ls` | `fn ls(path: string = "."): List<DirEntry> ! FsError` | Lists directory entries. Entry order is unspecified. |
| `rmdir` | `fn rmdir(path: string, recursive: bool = false): void ! FsError` | Removes an empty directory. With `recursive = true`, removes its contents first. |
| `stdin` | `fn stdin(): Stdin` | Returns the standard-input handle. |
| `stdout` | `fn stdout(): Stdout` | Returns the standard-output handle. |
| `stderr` | `fn stderr(): Stderr` | Returns the standard-error handle. |

## Instance methods

### `File`

| Method | Signature | Description |
| --- | --- | --- |
| `read` | `fn read(self: &File, dest: []u8): usize ! io.IoError` | Reads through `std.io.Reader`. |
| `write` | `fn write(self: &File, data: []const u8): usize ! io.IoError` | Writes through `std.io.Writer`. |
| `close` | `fn close(self: File): void ! FsError` | Flushes and closes the file. This consumes the handle. |

### `Stdin`

| Method | Signature | Description |
| --- | --- | --- |
| `read` | `fn read(self: &Stdin, dest: []u8): usize ! io.IoError` | Reads through `std.io.Reader`. |

### `Stdout` and `Stderr`

| Method | Signature | Description |
| --- | --- | --- |
| `write` | `fn write(self: &Stdout, data: []const u8): usize ! io.IoError` | Writes through `std.io.Writer`. The same method exists on `Stderr`. |
| `flush` | `fn flush(self: &Stdout): void ! io.IoError` | Reports buffered write failures. The same method exists on `Stderr`. |

## Errors

| Error | Meaning |
| --- | --- |
| `FsError.not_found` | The path does not exist. |
| `FsError.permission_denied` | The caller lacks access. |
| `FsError.already_exists` | The path already exists. |
| `FsError.invalid_path` | The path is not valid for the host. |
| `FsError.io_error` | Another I/O failure occurred. |
| `FsError.invalid_mode` | The `OpenMode` flags do not describe a valid open intent. |

## Example

```cyna
import std.io;
import { FsError, OpenMode, open } from std.fs;

fn save(path: string, data: []const u8): void ! FsError {
    var file = try open(path, OpenMode.write | OpenMode.create | OpenMode.truncate);
    io.write_all(&file, data) catch (write_problem) {
        file.close() catch (close_problem) {
            return FsError.io_error;
        };
        return FsError.io_error;
    };
    try file.close();
    return;
}
```

Use the whole-file helpers for small files. For larger streams, open a `File`
and use the [std.io](std-io.md) protocols.

`open_write(path)` is shorthand for `open(path, OpenMode.write |
OpenMode.create | OpenMode.truncate)`. To append without truncating, use
`OpenMode.write | OpenMode.create | OpenMode.append`.

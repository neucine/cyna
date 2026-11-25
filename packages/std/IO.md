# Byte input and output

`std.io` defines `Reader` and `Writer` protocols for byte streams. A reader
fills a caller-owned `[]u8` and returns the count. Zero means end of input.
A writer accepts `[]const u8` and returns how many bytes it wrote. Both may
return `IoError`. These APIs are available on freestanding targets; a
`thumbv7em-none-eabi` project using `read_to_end` passes semantic checking.

`read_to_end(reader, max_bytes)` collects at most `max_bytes` bytes into an
owned `List<u8>`. It returns `IoError.limit_exceeded` if more data arrives.
At the limit it reads one extra byte to distinguish end of input from excess
data. It also rejects a reader that reports more bytes than requested.
The list grows through the active root allocator.

`write_all(writer, data)` keeps calling the writer until all bytes have been
reported written. It returns `IoError.no_progress` if the writer returns zero
while bytes remain, and `IoError.invalid_count` if the writer reports more
bytes than supplied. An empty input succeeds without calling the writer.

Implementations can map their own read or write failures to
`IoError.read_failed` and `IoError.write_failed`.

## Files

On hosted targets, `std.fs.open(path, mode)` returns an owned `File`.
`open_read(path)` and `open_write(path)` are shorthands for common modes;
`open_write` creates or truncates the file. `File` implements both byte stream
protocols, so it works with `read_to_end` and `write_all`. Opened files must be
closed explicitly with `file.close()`; closing consumes the handle and reports
a final flush failure. A mutable binding is needed when borrowing the file for
a read or write.

```cyna
import std.fs;
import std.io;
import { FsError } from std.fs;

fn save(path: string, data: []const u8): void ! FsError {
    var file = try fs.open_write(path);
    io.write_all(&file, data) catch (code) {
        file.close() catch (close_code) { throw FsError.io_error; };
        throw FsError.io_error;
    };
    try file.close();
    return;
}
```

File reads return zero at end of input. A file opened for the wrong direction
reports an I/O error. `std.fs` still has its whole-file helpers for small files.

## Standard streams

`std.fs` provides `stdin()`, `stdout()`, and `stderr()` on its hosted targets.
They implement the relevant byte stream protocol.
`stdout()` and `stderr()` provide `flush()` to report buffered write failures.
These stream values do not own the process streams and must not be closed.
On Windows, their first read or write switches the process stream to binary
mode so bytes are not translated by the C runtime.

The global `std.io.install_writer` callback continues to route runtime
printing; it is separate from these byte stream values. `std.process`
captured output still has its own API and does not yet expose pipe streams.

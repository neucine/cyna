# std.io

`std.io` defines byte-oriented reading and writing protocols and helpers.

Available on all bundled targets.

```cyna
import { IoError, Reader, Writer, write_all } from std.io;
```

## Types

### `Reader`

Protocol for sequential byte input. A reader returns `0` only at end of input
and never reports more bytes than the destination can hold.

### `Writer`

Protocol for sequential byte output. A writer may accept fewer bytes than
supplied but must report the count it accepted.

### `WriterWriteFn`

The callback type used by `install_writer`:

```cyna
type WriterWriteFn = c fn (*c_char, c_llong, ?*c_void): void
```

## Static functions

Call these through the module or an imported name.

| Function | Signature | Description |
| --- | --- | --- |
| `read_to_end` | `fn read_to_end<R: Reader>(reader: &R, max_bytes: usize): List<u8> ! IoError` | Reads at most `max_bytes` into an owned list. |
| `write_all` | `fn write_all<W: Writer>(writer: &W, data: []const u8): void ! IoError` | Repeats partial writes until every byte is written. |
| `write_string` | `fn write_string(value: string): void` | Writes a string through the builtin print path. |
| `write_line` | `fn write_line(value: string): void` | Writes a string and a newline through the builtin print path. |
| `install_writer` | `fn install_writer(write_fn: WriterWriteFn, ctx: ?*c_void): void` | Routes `print` and `println` through a callback. |
| `clear_writer` | `fn clear_writer(): void` | Restores the default writer. |

`read_to_end` reports `limit_exceeded` when more data exists after the limit
and `invalid_count` when a reader claims to have read more bytes than
requested. `write_all` reports `no_progress` when a writer accepts zero bytes
while input remains.

## Instance methods

### `Reader`

| Method | Signature | Contract |
| --- | --- | --- |
| `read` | `fn read(self: &Self, dest: []u8): usize ! IoError` | Fills a caller-owned buffer and returns the byte count. Zero means end of input. |

### `Writer`

| Method | Signature | Contract |
| --- | --- | --- |
| `write` | `fn write(self: &Self, data: []const u8): usize ! IoError` | Writes some or all bytes and returns the byte count. |

## Errors

| Error | Meaning |
| --- | --- |
| `IoError.read_failed` | A read operation failed. |
| `IoError.write_failed` | A write operation failed. |
| `IoError.limit_exceeded` | More input remains after `read_to_end` reached its limit. |
| `IoError.invalid_count` | A reader or writer reported an impossible byte count. |
| `IoError.no_progress` | A writer accepted no bytes while input remained. |

## Example

```cyna
import { IoError, Writer, write_all } from std.io;

fn save<W: Writer>(writer: &W, message: string): void ! IoError {
    try write_all(writer, message.bytes());
    return;
}
```

`install_writer` changes where `print` and `println` send output. It is separate
from [std.fs](FS.md) stream handles.

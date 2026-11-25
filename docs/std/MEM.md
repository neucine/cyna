# std.mem

`std.mem` provides byte-slice operations that do not allocate. Use it for
protocol data, buffers, and text that is already in byte form.

Available on all bundled targets.

```cyna
import { MemError, copy_into, fill, index_of } from std.mem;
```

## Static functions

Call these through the module or an imported name.

| Function | Signature | Description |
| --- | --- | --- |
| `index_of` | `fn index_of(haystack: []const u8, needle: []const u8): ?usize` | Returns the first matching byte offset, or `none`. |
| `contains` | `fn contains(haystack: []const u8, needle: []const u8): bool` | Reports whether the needle occurs. |
| `starts_with` | `fn starts_with(haystack: []const u8, prefix: []const u8): bool` | Checks the beginning of a byte slice. |
| `ends_with` | `fn ends_with(haystack: []const u8, suffix: []const u8): bool` | Checks the end of a byte slice. |
| `fill` | `fn fill(dest: []u8, value: u8): void` | Writes one byte value to every position. |
| `zero` | `fn zero(dest: []u8): void` | Fills a byte slice with zeroes. |
| `copy_into` | `fn copy_into(dest: []u8, source: []const u8): void ! MemError` | Copies into the beginning of `dest`. |

`index_of` returns `0` for an empty needle. `copy_into` does not handle
overlapping ranges and does not extend the destination.

## Errors

| Error | Meaning |
| --- | --- |
| `MemError.destination_too_small` | The destination cannot hold the source. |

## Example

```cyna
import { MemError, copy_into, fill } from std.mem;

fn fill_buffer(bytes: []u8): void ! MemError {
    fill(bytes, 0);
    try copy_into(bytes, "cyna".bytes());
    return;
}
```

Use `string` methods for text and `std.mem` for byte data.

# std.path

`std.path` works with path strings without opening files. Path syntax follows
the host target.

Available on macOS arm64, Linux x86-64, and Windows x86-64.

```cyna
import { basename, extension, join } from std.path;
```

## Static functions

Call these through the module or an imported name.

| Function | Signature | Description |
| --- | --- | --- |
| `join` | `fn join(parts: []const string): string` | Combines path components for the host target. |
| `basename` | `fn basename(path: string): string` | Returns the final path component. |
| `dirname` | `fn dirname(path: string): string` | Returns the parent component. |
| `extension` | `fn extension(path: string): ?string` | Returns the extension without the dot, or `none`. |
| `stem` | `fn stem(path: string): string` | Returns the final component without its extension. |
| `is_absolute` | `fn is_absolute(path: string): bool` | Reports whether the path is absolute. |

`join`, `basename`, `dirname`, and `stem` return owned strings.

## Example

```cyna
import { basename, extension } from std.path;

fn has_extension(path: string): bool {
    if extension(path) is suffix {
        return suffix.len() > 0;
    }
    return false;
}
```

Do not compare paths built for different host targets without normalizing them
first.

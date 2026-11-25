# std.alloc

`std.alloc` installs the allocation source used by allocation-backed standard
library operations. Install a root allocator during startup.

Available on all bundled targets.

```cyna
import { RootAllocator, has_root, install_root_allocator } from std.alloc;
```

## Types

### `RootAllocator`

Holds the callbacks the standard library uses for allocation, reallocation, and
freeing.

| Field | Type | Meaning |
| --- | --- | --- |
| `ctx` | `*c_void` | User context passed to every callback. |
| `alloc_fn` | `c fn (*c_void, c_size_t): *c_void` | Allocates a block. |
| `realloc_fn` | `c fn (*c_void, *c_void, c_size_t): *c_void` | Resizes a block. |
| `free_fn` | `c fn (*c_void, *c_void): void` | Releases a block. |

## Static functions

Call these through the module or an imported name.

| Function | Signature | Description |
| --- | --- | --- |
| `install_root_allocator` | `fn install_root_allocator(allocator: RootAllocator): void` | Installs a callback-backed root allocator. |
| `init_bump_root` | `fn init_bump_root(heap: []u8): void` | Installs a bump allocator over a byte range. |
| `clear_root` | `fn clear_root(): void` | Removes the installed allocator. |
| `has_root` | `fn has_root(): bool` | Reports whether an allocator is installed. |

## Example

```cyna
import { RootAllocator, install_root_allocator } from std.alloc;

fn configure(allocator: RootAllocator): void {
    install_root_allocator(allocator);
}
```

A bump allocator does not reuse individual allocations. Keep its backing byte
range alive while any value allocated from it is still in use.

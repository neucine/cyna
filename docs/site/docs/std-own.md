# std.own

`std.own` shares one owned value by reference count across threads.

Available on macOS arm64 and Linux x86-64.

```cyna
import { Arc, arc } from std.own;
```

## Types

### `Arc<T>`

A shared claim on a reference-counted value. Access happens through a callback.

## Static functions

Call these through the module or an imported name.

| Function | Signature | Description |
| --- | --- | --- |
| `arc` | `fn arc<T>(value: T): Arc<T>` | Wraps a value in an `Arc<T>`. |

## Instance methods

### `Arc<T>`

| Method | Signature | Description |
| --- | --- | --- |
| `is_valid` | `fn is_valid(self: Arc<T>): bool` | Reports whether the handle refers to live storage. |
| `with` | `fn with<U>(self: Arc<T>, context: U, action: fn (&T, U): void): SyncStatus` | Runs a callback with a borrowed `&T`. |
| `with_result` | `fn with_result<U, R>(self: Arc<T>, context: U, action: fn (&T, U): R): R ! SyncStatus` | Runs a callback and returns its result. |
| `clone` | `fn clone(self: &const Arc<T>): Arc<T>` | Retains another claim through the `Clone` protocol. |

`clone` does not deep-copy the value. The value is released when the final
claim ends.

## Example

```cyna
import { arc } from std.own;

fn read(value: &i32, unused: i32): i32 {
    return *value;
}

fn use_shared(value: i32): i32 {
    const shared = arc(value);
    return shared.with_result(0, read) catch (code) {
        return 0;
    };
}
```

`Arc` operations use trusted synchronization support. Ordinary user types
cannot opt into that authority by using the same method names.

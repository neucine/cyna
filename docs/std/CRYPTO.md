# std.crypto

`std.crypto` computes SHA-256 digests and HMAC-SHA-256 tags over byte slices.

Available on macOS arm64, Linux x86-64, and Windows x86-64.

```cyna
import { hmac_sha256, sha256, verify_hmac_sha256 } from std.crypto;
```

## Static functions

Call these through the module or an imported name.

| Function | Signature | Description |
| --- | --- | --- |
| `sha256` | `fn sha256(data: []const u8): [32]u8` | Returns a 32-byte SHA-256 digest. |
| `hmac_sha256` | `fn hmac_sha256(key: []const u8, data: []const u8): [32]u8` | Returns a 32-byte HMAC-SHA-256 tag. |
| `verify_hmac_sha256` | `fn verify_hmac_sha256(key: []const u8, data: []const u8, tag: []const u8): bool` | Compares a tag in constant time. |

These functions do not allocate. `verify_hmac_sha256` returns `false` when the
tag is not exactly 32 bytes.

## Example

```cyna
import { hmac_sha256, verify_hmac_sha256 } from std.crypto;

fn check(key: []const u8, message: []const u8): bool {
    const tag = hmac_sha256(key, message);
    return verify_hmac_sha256(key, message, tag[..]);
}
```

The module does not provide encryption, random bytes, password hashing, or key
storage.

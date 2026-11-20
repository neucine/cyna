# Cryptography in the standard library

`std.crypto` currently provides SHA-256, HMAC-SHA-256, and HMAC tag
verification. All inputs are byte slices. Each digest is a `[32]u8` value.

```cyna
import std.crypto;

fn main(): i32 {
    const message = "hello".bytes();
    const digest = crypto.sha256(message);
    const tag = crypto.hmac_sha256("secret".bytes(), message);
    if digest[0] != 0x2c {
        return 2;
    }
    if crypto.verify_hmac_sha256("secret".bytes(), message, tag[..]) {
        return 0;
    }
    return 1;
}
```

SHA-256 identifies the contents of bytes but does not prove who supplied them.
HMAC-SHA-256 authenticates a message when the caller keeps its key secret.
`verify_hmac_sha256` accepts only a 32-byte tag and compares all tag bytes
without a source-level early exit. It does not make surrounding application
code constant time.

These operations do not allocate. The implementation uses a bundled C source
with no external cryptography library. The package manifest lists macOS arm64,
Linux x86-64, and Windows x86-64. Native behavior has been verified on macOS
arm64; the other listed targets still need native verification.
The bundled implementation has not had an independent security review.

The algorithm definitions are [FIPS 180-4](https://csrc.nist.gov/pubs/fips/180-4/final)
for SHA-256 and [FIPS 198-1](https://csrc.nist.gov/pubs/fips/198-1/final)
for HMAC. This module has no encryption, secure random-byte, password-hashing,
or key-storage API.

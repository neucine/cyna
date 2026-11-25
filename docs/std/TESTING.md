# std.testing

`std.testing` provides assertions for `test` blocks. A failed expectation
returns `TestError.failed`, which `cyna test` reports.

Available on every bundled target except Windows x86-64.

```cyna
import { expect, expect_eq_i32, fail } from std.testing;
```

## Static functions

Call these through the module or an imported name.

| Function | Signature | Description |
| --- | --- | --- |
| `fail` | `fn fail(): void ! TestError` | Fails immediately. |
| `expect` | `fn expect(value: bool): void ! TestError` | Requires a true condition. |
| `expect_eq_i32` | `fn expect_eq_i32(actual: i32, expected: i32): void ! TestError` | Compares two `i32` values. |
| `expect_eq_i64` | `fn expect_eq_i64(actual: i64, expected: i64): void ! TestError` | Compares two `i64` values. |
| `expect_eq_u8` | `fn expect_eq_u8(actual: u8, expected: u8): void ! TestError` | Compares two `u8` values. |
| `expect_eq_usize` | `fn expect_eq_usize(actual: usize, expected: usize): void ! TestError` | Compares two `usize` values. |
| `expect_eq_bool` | `fn expect_eq_bool(actual: bool, expected: bool): void ! TestError` | Compares two booleans. |
| `expect_eq_string` | `fn expect_eq_string(actual: string, expected: string): void ! TestError` | Compares string contents. |
| `expect_eq_bytes` | `fn expect_eq_bytes(actual: []const u8, expected: []const u8): void ! TestError` | Compares byte-slice contents. |

## Errors

| Error | Meaning |
| --- | --- |
| `TestError.failed` | An expectation did not hold. |

## Example

```cyna
import { expect_eq_i32 } from std.testing;

fn add(a: i32, b: i32): i32 {
    return a + b;
}

test "addition" {
    try expect_eq_i32(add(40, 2), 42);
}
```

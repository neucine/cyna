# Cyna 0.4.0 release notes

## Typed failures

Functions return typed failures with `T!E`, where `E` is an error enum or a
closed union of error enums. Successful paths use `return value`; failure paths
use `throw code` or `throw code, "message"`. `try` propagates a failure, and an
ordinary `catch (code)` block can handle it. The former public `result<T, E>`
type, `.ok` and `.err` result cases, and result switches are no longer accepted.
`T!E` is a function return form and cannot be stored or named inside `Task<T!E>`.

An optional `catch (code, failure)` binding reads a scoped diagnostic view.
`failure.available`, `origin`, `origin_file`, `message`, `site_count`, `site(i)`,
`site_file(i)`, and `omitted` expose the recorded throw and propagation sites.
Messages are copied into owned strings. The view cannot be stored, passed, or
used after the catch. A missing record leaves the typed code intact and gives
code-only diagnostic defaults.

Hosted task results preserve traces through `join`, ready `try_join`, nested
propagation, and discard. Freestanding builds currently provide typed codes
with code-only diagnostics.

## Other language and library changes

`switch` arms use `pattern => expression` or `pattern => { ... }`, with `_` as
the fallback arm. The former `case` and `else` arm spellings are rejected.
Named unions and type unions retain their distinct pattern forms. Stable owned
struct fields can be bound as projected locals under the current ownership
rules; indexed elements and checked payloads remain outside that rule.

The core `std.json` module provides strict RFC 8259 parsing, validation, and
encoding. Its parsing and validation functions use `T!E` returns like the
rest of the public library. The compiler's semantic implementation was also
split into focused owner modules; that refactor does not add source syntax.

## Migration example

```cyna
enum Failure { invalid = 1; }

fn read_value(valid: bool): i32!Failure {
    if !valid { throw Failure.invalid, "invalid input"; }
    return 42;
}

fn main(): i32 {
    return read_value(false) catch (code, failure) {
        if failure.available and code == Failure.invalid { yield 1; }
        yield 2;
    };
}
```

See [the language spec](spec.md) for the complete error-return contract and
[the concurrency guide](concurrency.md) for task result behavior.

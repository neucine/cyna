# std.json

`std.json` provides strict RFC 8259 parsing and serialization. It supports no
comments, trailing commas, `NaN`, or `Infinity`.

Available on all bundled targets.

```cyna
import { Error, Value, encode, parse } from std.json;
```

## Types

### `Value`

A closed union with these cases:

| Case | Payload |
| --- | --- |
| `null` | None. |
| `bool` | `bool` |
| `number` | `Number` |
| `string` | `string` |
| `array` | `Array` |
| `object` | `Object` |

### `Number`

| Field | Type | Meaning |
| --- | --- | --- |
| `spelling` | `string` | The validated number text, including exponents and negative zero. |

### `Member`

| Field | Type | Meaning |
| --- | --- | --- |
| `key` | `string` | Object key. |
| `value` | `Value` | Member value. |

### `Object` and `Array`

`Object.members` is an ordered `List<Member>`; `Array.items` is a
`List<Value>`. Objects preserve source order.

## Static functions

Call these through the module or an imported name.

| Function | Signature | Description |
| --- | --- | --- |
| `parse` | `fn parse(text: string): Value ! Error` | Parses a string into an owned value. |
| `parse_bytes` | `fn parse_bytes(text: []const u8): Value ! Error` | Validates UTF-8, then parses bytes. |
| `validate` | `fn validate(text: string): void ! Error` | Parses and discards the result. |
| `validate_bytes` | `fn validate_bytes(text: []const u8): void ! Error` | Validates bytes and discards the result. |
| `encode` | `fn encode(value: &const Value): string` | Serializes to compact JSON. |
| `encode_pretty` | `fn encode_pretty(value: &const Value): string` | Serializes with a two-space indent. |

## Instance methods

### `Number`

| Method | Signature | Description |
| --- | --- | --- |
| `text` | `fn text(self: &const Number): string` | Returns the original number spelling. |
| `is_integer` | `fn is_integer(self: &const Number): bool` | Reports whether the spelling has no fraction or exponent. |

### `Object`

| Method | Signature | Description |
| --- | --- | --- |
| `len` | `fn len(self: &const Object): usize` | Returns the member count. |
| `find` | `fn find(self: &const Object, key: string): ?usize` | Returns the member position, or `none`. |
| `contains` | `fn contains(self: &const Object, key: string): bool` | Reports whether a key exists. |
| `index` | `fn index(self: &const Object, key: string): &const Value` | Index syntax. Traps when the key is absent. |

### `Array`

| Method | Signature | Description |
| --- | --- | --- |
| `len` | `fn len(self: &const Array): usize` | Returns the item count. |
| `index` | `fn index(self: &const Array, index: usize): &const Value` | Index syntax. Traps when the position is absent. |

## Errors

| Error | Meaning |
| --- | --- |
| `Error.unexpected_end` | Input ended before the document was complete. |
| `Error.invalid_token` | A token or value is invalid. |
| `Error.invalid_escape` | A string escape is invalid. |
| `Error.invalid_unicode` | A Unicode escape is invalid. |
| `Error.trailing_data` | Non-whitespace data follows the document. |
| `Error.duplicate_key` | An object repeats a key. |
| `Error.depth_exceeded` | Nesting exceeds the parser limit. |
| `Error.invalid_utf8` | Byte input is not valid UTF-8. |

## Example

```cyna
import std.json;
import { Error } from std.json;

fn read_name(document: string): string ! Error {
    const value = try json.parse(document);
    switch value {
    .object(object) => {
        switch object["name"] {
        .string(name) => {
            return name.clone();
        }
        _ => {
            throw Error.invalid_token;
        }
        }
    }
    _ => {
        throw Error.invalid_token;
    }
    }
}
```

Parsed strings, numbers, arrays, and members are owned by the returned value.
Keep that value alive while using borrowed children.

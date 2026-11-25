# std.config

`std.config` gives a setting a type, default, environment name, and explicit
parser. Applications group settings in their own structs.

Available on macOS arm64 and Linux x86-64.

```cyna
import { ConfigError, Setting, parse_bool, startup } from std.config;
```

## Types

### `Setting<T>`

An owned setting value. Its fields are private; use the instance methods.

### `Mutability`

| Case | Meaning |
| --- | --- |
| `startup` | Writable until `freeze()` is called. |
| `runtime` | Remains writable. |
| `readonly` | Rejects changes. |

## Static functions

Call these through the module or an imported name.

| Function | Signature | Description |
| --- | --- | --- |
| `startup` | `fn startup<T>(env_name: string, default_value: T, parser: fn (string): T ! ConfigError): Setting<T>` | Creates a setting that can be frozen after startup. |
| `runtime` | `fn runtime<T>(env_name: string, default_value: T, parser: fn (string): T ! ConfigError): Setting<T>` | Creates a setting that remains writable. |
| `readonly` | `fn readonly<T>(env_name: string, default_value: T, parser: fn (string): T ! ConfigError): Setting<T>` | Creates a setting that rejects changes. |
| `parse_bool` | `fn parse_bool(raw: string): bool ! ConfigError` | Parses `true`, `false`, `yes`, `no`, `1`, `0`, `on`, or `off`. |
| `parse_positive_usize` | `fn parse_positive_usize(raw: string): usize ! ConfigError` | Parses a non-zero decimal integer that fits `usize`. |
| `parse_non_empty_string` | `fn parse_non_empty_string(raw: string): string ! ConfigError` | Accepts any string with at least one byte. |

## Instance methods

### `Setting<T>`

| Method | Signature | Description |
| --- | --- | --- |
| `get` | `fn get(self: &const Setting<T>): T` | Returns the current value. |
| `set` | `fn set(self: &Setting<T>, value: T): void ! ConfigError` | Replaces the value if the setting allows it. |
| `load_env` | `fn load_env(self: &Setting<T>): bool ! ConfigError` | Loads the named environment variable; returns whether it existed. |
| `freeze` | `fn freeze(self: &Setting<T>): void` | Locks a startup setting. |

## Errors

| Error | Meaning |
| --- | --- |
| `ConfigError.invalid_value` | A parser rejected the raw value. |
| `ConfigError.startup_locked` | A startup setting was changed after `freeze()`. |
| `ConfigError.readonly` | A readonly setting was changed. |

## Example

```cyna
import { ConfigError, parse_positive_usize, startup } from std.config;

fn configure(): bool ! ConfigError {
    var workers = startup<usize>("APP_WORKERS", 1, parse_positive_usize);
    const loaded = try workers.load_env();
    workers.freeze();
    return loaded;
}
```

If an environment variable is absent, `load_env` returns `false` and keeps the
current value. If parsing fails, the current value also stays unchanged.

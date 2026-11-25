# std.process

`std.process` reads process state, environment variables, and runs child
processes.

Available on macOS arm64, Linux x86-64, and Windows x86-64.

```cyna
import { CommandBuilder, ProcessError, Stdio, command } from std.process;
```

## Types

### `EnvPair`

| Field | Type | Meaning |
| --- | --- | --- |
| `key` | `string` | Variable name. |
| `value` | `string` | Variable value. |

### `ExitStatus`

| Field | Type | Meaning |
| --- | --- | --- |
| `code` | `?i32` | Exit code, or `none` when the platform cannot express one. |
| `success` | `bool` | Whether the child exited successfully. |

### `Output`

| Field | Type | Meaning |
| --- | --- | --- |
| `status` | `ExitStatus` | Child exit status. |
| `stdout` | `string` | Captured standard output. |
| `stderr` | `string` | Captured standard error. |

### `CommandBuilder`

An immutable child-process configuration. Each configuration method returns a
new builder.

### `Stdio`

| Case | Meaning |
| --- | --- |
| `inherit` | Use the parent's stream. |
| `null` | Discard the stream. |
| `piped` | Capture or connect the stream. |

## Static functions

Call these through the module or an imported name.

| Function | Signature | Description |
| --- | --- | --- |
| `command` | `fn command(program: string): CommandBuilder` | Starts a child-process configuration. |
| `args` | `fn args(): List<string>` | Returns an owned list of command-line arguments. |
| `env_list` | `fn env_list(): List<EnvPair> ! ProcessError` | Returns an owned list of environment pairs. |
| `cwd` | `fn cwd(): string ! ProcessError` | Returns the current working directory. |
| `exe_path` | `fn exe_path(): string ! ProcessError` | Returns the current executable path. |
| `pid` | `fn pid(): u32 ! ProcessError` | Returns the current process ID. |
| `parent_pid` | `fn parent_pid(): ?u32 ! ProcessError` | Returns the parent process ID, if available. |
| `env_get` | `fn env_get(key: string): ?string` | Returns an environment value, or `none`. |
| `env_set` | `fn env_set(key: string, value: string): void ! ProcessError` | Changes the current environment. |
| `env_unset` | `fn env_unset(key: string): void ! ProcessError` | Removes a variable from the current environment. |
| `stdin_is_tty` | `fn stdin_is_tty(): bool ! ProcessError` | Reports whether standard input is a terminal. |
| `stdout_is_tty` | `fn stdout_is_tty(): bool ! ProcessError` | Reports whether standard output is a terminal. |
| `stderr_is_tty` | `fn stderr_is_tty(): bool ! ProcessError` | Reports whether standard error is a terminal. |
| `exit` | `fn exit(code: i32): void` | Ends the process immediately. |

## Instance methods

### `CommandBuilder`

| Method | Signature | Description |
| --- | --- | --- |
| `arg` | `fn arg(self: CommandBuilder, value: string): CommandBuilder` | Adds one argument. |
| `args` | `fn args(self: CommandBuilder, values: []const string): CommandBuilder` | Adds several arguments. |
| `cwd` | `fn cwd(self: CommandBuilder, path: string): CommandBuilder` | Sets the child's working directory. |
| `env` | `fn env(self: CommandBuilder, key: string, value: string): CommandBuilder` | Adds one environment variable. |
| `clear_env` | `fn clear_env(self: CommandBuilder): CommandBuilder` | Starts with an empty environment. |
| `stdin` | `fn stdin(self: CommandBuilder, mode: Stdio): CommandBuilder` | Configures standard input. |
| `stdout` | `fn stdout(self: CommandBuilder, mode: Stdio): CommandBuilder` | Configures standard output. |
| `stderr` | `fn stderr(self: CommandBuilder, mode: Stdio): CommandBuilder` | Configures standard error. |
| `run` | `fn run(self: CommandBuilder): ExitStatus ! ProcessError` | Waits for completion. |
| `output` | `fn output(self: CommandBuilder): Output ! ProcessError` | Captures standard output and error. |

## Errors

| Error | Meaning |
| --- | --- |
| `ProcessError.not_found` | The program was not found. |
| `ProcessError.permission_denied` | The caller lacks permission to run it. |
| `ProcessError.invalid_argument` | An argument is invalid. |
| `ProcessError.invalid_utf8` | Captured data is not valid UTF-8. |
| `ProcessError.io_error` | An I/O operation failed. |
| `ProcessError.spawn_failed` | The child could not be started. |
| `ProcessError.wait_failed` | Waiting for the child failed. |

## Example

```cyna
import { ProcessError, command } from std.process;

fn has_cyna(): bool ! ProcessError {
    const result = try command("cyna").arg("version").run();
    return result.success;
}
```

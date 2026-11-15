pub enum ProcessError: i32 {
    not_found = 0,
    permission_denied,
    invalid_argument,
    invalid_utf8,
    io_error,
    spawn_failed,
    wait_failed,
}

pub enum Stdio: i32 {
    inherit = 0,
    null,
    piped,
}

pub struct EnvPair {
    pub key: string;
    pub value: string;
}

impl EnvPair: Clone {
    fn clone(self: &const EnvPair): EnvPair {
        return EnvPair {
            key: self.key.clone(),
            value: self.value.clone(),
        };
    }
}

pub struct ExitStatus {
    pub code: ?i32;
    pub success: bool;
}

pub struct Output {
    pub status: ExitStatus;
    pub stdout: string;
    pub stderr: string;
}

struct RawCommandBuilder {
    program: string;
    argv: []const string;
    cwd_path: ?string;
    env_pairs: []const EnvPair;
    clear_env_flag: bool;
    stdin_mode: Stdio;
    stdout_mode: Stdio;
    stderr_mode: Stdio;
}

pub struct CommandBuilder {
    pub program: string;
    pub argv: List<string>;
    pub cwd_path: ?string;
    pub env_pairs: List<EnvPair>;
    pub clear_env_flag: bool;
    pub stdin_mode: Stdio;
    pub stdout_mode: Stdio;
    pub stderr_mode: Stdio;

    pub fn arg(self: CommandBuilder, value: string): CommandBuilder {
        var next_argv = self.argv.clone();
        next_argv.push(value);
        return CommandBuilder {
            program: self.program,
            argv: next_argv,
            cwd_path: self.cwd_path,
            env_pairs: self.env_pairs.clone(),
            clear_env_flag: self.clear_env_flag,
            stdin_mode: self.stdin_mode,
            stdout_mode: self.stdout_mode,
            stderr_mode: self.stderr_mode,
        };
    }

    pub fn args(self: CommandBuilder, values: []const string): CommandBuilder {
        var next_argv = self.argv.clone();
        for value in values {
            next_argv.push(value);
        }
        return CommandBuilder {
            program: self.program,
            argv: next_argv,
            cwd_path: self.cwd_path,
            env_pairs: self.env_pairs.clone(),
            clear_env_flag: self.clear_env_flag,
            stdin_mode: self.stdin_mode,
            stdout_mode: self.stdout_mode,
            stderr_mode: self.stderr_mode,
        };
    }

    pub fn cwd(self: CommandBuilder, path: string): CommandBuilder {
        return CommandBuilder {
            program: self.program,
            argv: self.argv.clone(),
            cwd_path: path,
            env_pairs: self.env_pairs.clone(),
            clear_env_flag: self.clear_env_flag,
            stdin_mode: self.stdin_mode,
            stdout_mode: self.stdout_mode,
            stderr_mode: self.stderr_mode,
        };
    }

    pub fn env(self: CommandBuilder, key: string, value: string): CommandBuilder {
        var next_env_pairs = self.env_pairs.clone();
        next_env_pairs.push(EnvPair {
            key: key,
            value: value,
        });
        return CommandBuilder {
            program: self.program,
            argv: self.argv.clone(),
            cwd_path: self.cwd_path,
            env_pairs: next_env_pairs,
            clear_env_flag: self.clear_env_flag,
            stdin_mode: self.stdin_mode,
            stdout_mode: self.stdout_mode,
            stderr_mode: self.stderr_mode,
        };
    }

    pub fn clear_env(self: CommandBuilder): CommandBuilder {
        return CommandBuilder {
            program: self.program,
            argv: self.argv.clone(),
            cwd_path: self.cwd_path,
            env_pairs: [],
            clear_env_flag: true,
            stdin_mode: self.stdin_mode,
            stdout_mode: self.stdout_mode,
            stderr_mode: self.stderr_mode,
        };
    }

    pub fn stdin(self: CommandBuilder, mode: Stdio): CommandBuilder {
        return CommandBuilder {
            program: self.program,
            argv: self.argv.clone(),
            cwd_path: self.cwd_path,
            env_pairs: self.env_pairs.clone(),
            clear_env_flag: self.clear_env_flag,
            stdin_mode: mode,
            stdout_mode: self.stdout_mode,
            stderr_mode: self.stderr_mode,
        };
    }

    pub fn stdout(self: CommandBuilder, mode: Stdio): CommandBuilder {
        return CommandBuilder {
            program: self.program,
            argv: self.argv.clone(),
            cwd_path: self.cwd_path,
            env_pairs: self.env_pairs.clone(),
            clear_env_flag: self.clear_env_flag,
            stdin_mode: self.stdin_mode,
            stdout_mode: mode,
            stderr_mode: self.stderr_mode,
        };
    }

    pub fn stderr(self: CommandBuilder, mode: Stdio): CommandBuilder {
        return CommandBuilder {
            program: self.program,
            argv: self.argv.clone(),
            cwd_path: self.cwd_path,
            env_pairs: self.env_pairs.clone(),
            clear_env_flag: self.clear_env_flag,
            stdin_mode: self.stdin_mode,
            stdout_mode: self.stdout_mode,
            stderr_mode: mode,
        };
    }

    pub fn run(self: CommandBuilder): ExitStatus ! ProcessError {
        const raw = RawCommandBuilder {
            program: self.program,
            argv: self.argv.storage[..],
            cwd_path: self.cwd_path,
            env_pairs: self.env_pairs.storage[..],
            clear_env_flag: self.clear_env_flag,
            stdin_mode: self.stdin_mode,
            stdout_mode: self.stdout_mode,
            stderr_mode: self.stderr_mode,
        };
        const status = run_raw(raw) catch (code) {
            drop raw;
            throw code;
        };
        drop raw;
        return status;
    }

    pub fn output(self: CommandBuilder): Output ! ProcessError {
        const raw = RawCommandBuilder {
            program: self.program,
            argv: self.argv.storage[..],
            cwd_path: self.cwd_path,
            env_pairs: self.env_pairs.storage[..],
            clear_env_flag: self.clear_env_flag,
            stdin_mode: self.stdin_mode,
            stdout_mode: self.stdout_mode,
            stderr_mode: self.stderr_mode,
        };
        const out = output_raw(raw) catch (code) {
            drop raw;
            throw code;
        };
        drop raw;
        return out;
    }
}

pub extern c fn cwd(): string ! ProcessError;
pub extern c fn exe_path(): string ! ProcessError;
pub extern c fn pid(): u32 ! ProcessError;
pub extern c fn parent_pid(): ?u32 ! ProcessError;
@unchecked_thread_safe
pub extern c fn env_get(key: string): ?string;
pub extern c fn env_set(key: string, value: string): void ! ProcessError;
pub extern c fn env_unset(key: string): void ! ProcessError;
pub extern c fn stdin_is_tty(): bool ! ProcessError;
pub extern c fn stdout_is_tty(): bool ! ProcessError;
pub extern c fn stderr_is_tty(): bool ! ProcessError;
pub extern c fn exit(code: i32): void;

extern {
    c fn args_dense(): [:]string;
    c fn env_list_dense(): [:]EnvPair ! ProcessError;
    c fn run_raw(command: RawCommandBuilder): ExitStatus ! ProcessError;
    c fn output_raw(command: RawCommandBuilder): Output ! ProcessError;
}

pub fn args(): List<string> {
    const storage = args_dense();
    const capacity = storage.len();
    return List<string> {
        storage: storage,
        capacity: capacity,
    };
}

pub fn env_list(): List<EnvPair>!ProcessError {
    const storage = try env_list_dense();
    const capacity = storage.len();
    return List<EnvPair> {
        storage: storage,
        capacity: capacity,
    };
}

pub fn command(program: string): CommandBuilder {
    return CommandBuilder {
        program: program,
        argv: [],
        cwd_path: none,
        env_pairs: [],
        clear_env_flag: false,
        stdin_mode: Stdio.inherit,
        stdout_mode: Stdio.inherit,
        stderr_mode: Stdio.inherit,
    };
}

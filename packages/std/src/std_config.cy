import { env_get } from std.process;

pub enum ConfigError: i32 {
    invalid_value = 0,
    startup_locked,
    readonly,
}

pub enum Mutability: i32 {
    startup = 0,
    runtime,
    readonly,
}

// A setting owns its value. Applications group settings in an ordinary struct.
// The parser is explicit because Cyna has no struct field reflection.
pub struct Setting<T> {
    value: T;
    env_name: string;
    mutability: Mutability;
    locked: bool;
    parser: fn (string): T ! ConfigError;

    pub fn get(self: &const Setting<T>): T {
        return self.value;
    }

    pub fn set(self: &Setting<T>, value: T): void ! ConfigError {
        if self.mutability == Mutability.readonly {
            throw ConfigError.readonly;
        }
        if self.mutability == Mutability.startup and self.locked {
            throw ConfigError.startup_locked;
        }
        self.value = value;
    }

    pub fn load_env(self: &Setting<T>): bool ! ConfigError {
        const raw = env_get(self.env_name.clone());
        if raw is none {
            return false;
        }
        const parse = self.parser;
        const parsed = try parse(raw);
        try self.set(parsed);
        return true;
    }

    pub fn freeze(self: &Setting<T>): void {
        if self.mutability == Mutability.startup {
            self.locked = true;
        }
    }
}

pub fn startup<T>(env_name: string, default_value: T, parser: fn (string): T ! ConfigError): Setting<T> {
    return Setting<T> {
        value: default_value,
        env_name: env_name,
        mutability: Mutability.startup,
        locked: false,
        parser: parser
    };
}

pub fn runtime<T>(env_name: string, default_value: T, parser: fn (string): T ! ConfigError): Setting<T> {
    return Setting<T> {
        value: default_value,
        env_name: env_name,
        mutability: Mutability.runtime,
        locked: false,
        parser: parser
    };
}

pub fn readonly<T>(env_name: string, default_value: T, parser: fn (string): T ! ConfigError): Setting<T> {
    return Setting<T> {
        value: default_value,
        env_name: env_name,
        mutability: Mutability.readonly,
        locked: false,
        parser: parser
    };
}

pub fn parse_bool(raw: string): bool ! ConfigError {
    if raw == "true" or raw == "yes" or raw == "1" or raw == "on" {
        return true;
    }
    if raw == "false" or raw == "no" or raw == "0" or raw == "off" {
        return false;
    }
    throw ConfigError.invalid_value;
}

pub fn parse_positive_usize(raw: string): usize ! ConfigError {
    const bytes = raw.bytes();
    if bytes.len() == 0 {
        throw ConfigError.invalid_value;
    }
    var value: usize = 0;
    const max_value: usize = 18446744073709551615;
    for byte in bytes {
        if byte < 48 or byte > 57 {
            throw ConfigError.invalid_value;
        }
        const digit: usize = (byte - 48) as usize;
        if value > (max_value - digit) / 10 {
            throw ConfigError.invalid_value;
        }
        value = value * 10 + digit;
    }
    if value == 0 {
        throw ConfigError.invalid_value;
    }
    return value;
}

pub fn parse_non_empty_string(raw: string): string ! ConfigError {
    if raw.len() == 0 {
        throw ConfigError.invalid_value;
    }
    return raw;
}

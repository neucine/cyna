import { env_get, env_set } from std.process;

fn is_ready(value: string): bool {
    return value == "ready";
}

struct Check {
    name: string;
    value: bool;
    callback: fn (string): bool;
}

fn load(check: &Check): bool {
    const raw = env_get(check.name.clone());
    if raw is value {
        const callback = check.callback;
        check.value = callback(value);
        return true;
    }
    return false;
}

fn main(): i32 {
    env_set("CYNA_INDIRECT_CALLBACK_VALUE", "ready") catch (code) {
        return 1;
    };
    var check = Check {
        name: "CYNA_INDIRECT_CALLBACK_VALUE",
        value: false,
        callback: is_ready,
    };
    const first = load(&check);
    const second = load(&check);
    if first and second and check.value {
        return 42;
    }
    return 1;
}

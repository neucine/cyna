const FALLBACK: i32 = 3;

struct Config {
    rate: f32;
    beta: f32 = 0.9;
    label: string = "ready";
}

struct Box<T> {
    value: T;
    count: i32 = FALLBACK;
}

fn main(): i32 {
    const plain = Config {
        rate: 0.0
    };
    const contextual: Config = {
        rate: 0.0,
        beta: 0.5
    };
    const owned = new Config {
        rate: 0.0
    };
    const generic = Box<i32> {
        value: 7
    };
    if plain.beta > contextual.beta and owned.beta == plain.beta and
    plain.label == "ready" and generic.count == 3 {
        return 42;
    }
    return 1;
}

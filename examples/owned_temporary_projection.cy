enum Failure {
    invalid;
}

struct Box {
    value: string;
}

fn make_box(): Box ! Failure {
    return Box {
        value: "ready"
    };
}

fn fails(): i32 ! Failure {
    throw Failure.invalid;
}

fn probe(): bool ! Failure {
    const outcome = fails() catch (code) {
        return code == Failure.invalid and (try make_box()).value == "ready";
    };
    const ignored = outcome;
    return false;
}

fn main(): i32 {
    const passed = probe() catch (code) {
        const ignored = code;
        return 1;
    };
    if passed {
        return 42;
    }
    return 2;
}

struct Backend {
    callback: fn (inputs: &const List<*c_void>): usize;
}

fn count(inputs: &const List<*c_void>): usize {
    return inputs.len();
}

fn run(backend: &const Backend): usize {
    var operands: List<*c_void> = list<*c_void>();
    const callback = backend.callback;
    return callback(&operands);
}

fn main(): i32 {
    const backend = Backend {
        callback: count
    };
    if run(&backend) == 0 {
        return 42;
    }
    return 1;
}

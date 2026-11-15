struct StatusReg {
    ready: u1;
    mode: u3;
    error: u4;
}

fn main(): i32 {
    const status = StatusReg {
        ready: 1,
        mode: 5,
        error: 0
    };

    return 36 + status.ready + status.mode + status.error;
}

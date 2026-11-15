import { MemError, copy_into, fill, zero } from std.mem;

fn run(): i32 ! MemError {
    var data: [:]u8 = [0, 0, 0, 0, 0];
    var view: []u8 = data[..];

    fill(view, 65);
    if data[0] != 65 or data[1] != 65 or data[2] != 65 or data[3] != 65 or data[4] != 65 {
        return 1;
    }

    zero(view);
    if data[0] != 0 or data[1] != 0 or data[2] != 0 or data[3] != 0 or data[4] != 0 {
        return 2;
    }

    try copy_into(view, "cyna".bytes());

    if data[0] != 99 or data[1] != 121 or data[2] != 110 or data[3] != 97 or data[4] != 0 {
        return 3;
    }

    copy_into(view, "too long".bytes()) catch (code) {
        if code == MemError.destination_too_small {
            return 42;
        }
        return 5;
    };
    return 4;
}

fn main(): i32 {
    return run() catch (code) {
        yield 1;
    };
}

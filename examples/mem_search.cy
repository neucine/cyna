import std.mem;

fn main(): i32 {
    const data = "cyna runtime".bytes();
    const found = mem.index_of(data, "runtime".bytes());
    const missing = mem.index_of(data, "system".bytes());
    const empty = mem.index_of(data, "".bytes());

    if found != none and missing == none and empty != none {
        if mem.contains(data, "na".bytes()) and not mem.contains(data, "zz".bytes()) {
            if mem.starts_with(data, "cy".bytes()) and mem.ends_with(data, "time".bytes()) {
                return 42;
            }
        }
    }

    return 1;
}

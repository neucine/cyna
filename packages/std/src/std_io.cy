pub type WriterWriteFn = c fn (*c_char, c_llong, ?*c_void): void;

pub extern c fn install_writer(write_fn: WriterWriteFn, ctx: ?*c_void): void;
pub extern c fn clear_writer(): void;

pub fn write_string(value: string): void {
    print(value);
}

pub fn write_line(value: string): void {
    println(value);
}

pub enum IoError: i32 {
    read_failed = 0,
    write_failed,
    limit_exceeded,
    invalid_count,
    no_progress,
}

// A zero read means end of input. A reader must never return more than dest.len().
pub protocol Reader {
    fn read(self: &Self, dest: []u8): usize ! IoError;
}

// A writer may write fewer bytes than supplied, but must report the count.
pub protocol Writer {
    fn write(self: &Self, data: []const u8): usize ! IoError;
}

pub fn read_to_end<R: Reader>(reader: &R, max_bytes: usize): List<u8> !IoError {
    var output: List<u8> = list<u8>();
    var scratch: [4096]u8 = [];
    while true {
        const remaining = max_bytes - output.len();
        var requested: usize = 4096;
        if remaining == 0 {
            requested = 1;
        } else if remaining < 4096 {
            requested = remaining;
        }
        const count = try reader.read(scratch[..requested]);
        if count > requested {
            throw IoError.invalid_count;
        }
        if count == 0 {
            return output;
        }
        if remaining == 0 {
            throw IoError.limit_exceeded;
        }
        var index: usize = 0;
        while index < count {
            output.push(scratch[index]);
            index = index + 1;
        }
    }
}

pub fn write_all<W: Writer>(writer: &W, data: []const u8): void ! IoError {
    var offset: usize = 0;
    while offset < data.len() {
        const count = try writer.write(data[offset..]);
        if count > data.len() - offset {
            throw IoError.invalid_count;
        }
        if count == 0 {
            throw IoError.no_progress;
        }
        offset = offset + count;
    }
    return;
}

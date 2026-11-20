import std.io;
import { Reader, Writer, IoError } from std.io;

struct ChunkReader {
    text: string;
    position: usize;
    invalid: bool;
}
impl ChunkReader: Reader {
    fn read(self: &ChunkReader, dest: []u8): usize ! IoError {
        if self.invalid {
            return dest.len() + 1;
        }
        const bytes = self.text.bytes();
        var count: usize = 0;
        while count < dest.len() and self.position < bytes.len() {
            dest[count] = bytes[self.position];
            self.position = self.position + 1;
            count = count + 1;
        }
        return count;
    }
}
struct ChunkWriter {
    bytes: List<u8>;
    stall: bool;
}
impl ChunkWriter: Writer {
    fn write(self: &ChunkWriter, data: []const u8): usize ! IoError {
        if self.stall {
            return 0;
        }
        if data.len() == 0 {
            return 0;
        }
        self.bytes.push(data[0]);
        return 1;
    }
}
fn read_limited(): void ! IoError {
    var reader = ChunkReader {
        text: "hello",
        position: 0,
        invalid: false
    };
    const ignored = try io.read_to_end(&reader, 4);
    return;
}
fn read_invalid(): void ! IoError {
    var reader = ChunkReader {
        text: "hello",
        position: 0,
        invalid: true
    };
    const ignored = try io.read_to_end(&reader, 5);
    return;
}
fn write_stalled(): void ! IoError {
    var writer = ChunkWriter {
        bytes: list<u8>(),
        stall: true
    };
    try io.write_all(&writer, "x".bytes());
    return;
}
fn run(): i32 ! IoError {
    var reader = ChunkReader {
        text: "hello",
        position: 0,
        invalid: false
    };
    const data = try io.read_to_end(&reader, 5);
    if data.len() != 5 {
        return 1;
    }
    var writer = ChunkWriter {
        bytes: list<u8>(),
        stall: false
    };
    try io.write_all(&writer, data[..]);
    if writer.bytes.len() != 5 {
        return 2;
    }
    if writer.bytes[4] != 111 {
        return 3;
    }
    var saw_limit = false;
    read_limited() catch (code) {
        if code != IoError.limit_exceeded {
            return 4;
        }
        saw_limit = true;
    };
    if not saw_limit {
        return 5;
    }
    var saw_invalid = false;
    read_invalid() catch (code) {
        if code != IoError.invalid_count {
            return 6;
        }
        saw_invalid = true;
    };
    if not saw_invalid {
        return 7;
    }
    var saw_stall = false;
    write_stalled() catch (code) {
        if code != IoError.no_progress {
            return 8;
        }
        saw_stall = true;
    };
    if not saw_stall {
        return 9;
    }
    return 42;
}
fn main(): i32 {
    return run() catch (problem) {
        return 99;
    };
}

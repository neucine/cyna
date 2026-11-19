import std.fs;
import std.io;
import { File, FsError } from std.fs;
import { IoError } from std.io;

fn read_limited(file: &File): void ! IoError {
    const ignored = try io.read_to_end(file, 4);
    return;
}

fn open_missing(path: string): void ! FsError {
    var file = try fs.open_read($"{path}.missing");
    try file.close();
    return;
}

fn write_file(path: string): i32 ! FsError {
    var file = try fs.open_write(path);
    io.write_all(&file, "hello".bytes()) catch (code) {
        file.close() catch (close_code) {
            return 3;
        };
        return 1;
    };
    try file.close();
    return 0;
}

fn read_file(path: string): i32 ! FsError {
    var file = try fs.open_read(path);
    const data = io.read_to_end(&file, 5) catch (code) {
        file.close() catch (close_code) {
            return 4;
        };
        return 2;
    };
    try file.close();
    if data.len() != 5 or data[4] != 111 {
        return 5;
    }

    var limited = try fs.open_read(path);
    var saw_limit = false;
    read_limited(&limited) catch (code) {
        if code != IoError.limit_exceeded {
            return 6;
        }
        saw_limit = true;
    };
    try limited.close();
    if not saw_limit {
        return 7;
    }
    return 0;
}

fn run(): i32 ! FsError {
    const path = "__FILE_PATH__";
    const written = try write_file(path);
    if written != 0 {
        return written;
    }
    const read = try read_file(path);
    if read != 0 {
        return read;
    }
    var saw_missing = false;
    open_missing(path) catch (code) {
        if code != FsError.not_found {
            return 8;
        }
        saw_missing = true;
    };
    if not saw_missing {
        return 9;
    }
    return 42;
}

fn main(): i32 {
    return run() catch (code) {
        return 99;
    };
}

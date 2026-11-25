import std.fs;
import std.io;
import { FsError, OpenMode } from std.fs;

fn open_for_invalid_mode(path: string): void ! FsError {
    var file = try fs.open(path, OpenMode.truncate);
    try file.close();
    return;
}

fn open_new(path: string): void ! FsError {
    var file = try fs.open(path, OpenMode.write | OpenMode.create_new);
    try file.close();
    return;
}

fn write_once(path: string, data: []const u8): void ! FsError {
    var file = try fs.open(path, OpenMode.write | OpenMode.create | OpenMode.truncate);
    io.write_all(&file, data) catch (code) {
        file.close() catch (close_code) {
            return FsError.io_error;
        };
        return FsError.io_error;
    };
    try file.close();
    return;
}

fn append(path: string, data: []const u8): void ! FsError {
    var file = try fs.open(path, OpenMode.write | OpenMode.append);
    io.write_all(&file, data) catch (code) {
        file.close() catch (close_code) {
            return FsError.io_error;
        };
        return FsError.io_error;
    };
    try file.close();
    return;
}

fn run(): i32 ! FsError {
    const path = "__FILE_PATH__";
    const append_path = $"{path}.append";
    try write_once(append_path, "hello".bytes());
    try append(append_path, "!".bytes());
    if try fs.read_file(append_path) != "hello!" {
        return 1;
    }

    const new_path = $"{path}.new";
    try open_new(new_path);
    var saw_exists = false;
    open_new(new_path) catch (code) {
        if code != FsError.already_exists {
            return 2;
        }
        saw_exists = true;
    };
    if not saw_exists {
        return 3;
    }

    var saw_invalid_mode = false;
    open_for_invalid_mode(path) catch (code) {
        if code != FsError.invalid_mode {
            return 4;
        }
        saw_invalid_mode = true;
    };
    if not saw_invalid_mode {
        return 5;
    }

    const dir = $"{path}.dir";
    try fs.mkdir($"{dir}/nested", recursive = true);
    const entries = try fs.ls(dir);
    if entries.len() != 1 {
        return 6;
    }
    try fs.rmdir(dir, recursive = true);
    if try fs.exists(dir) {
        return 7;
    }
    return 42;
}

fn main(): i32 {
    return run() catch (code) {
        return 99;
    };
}

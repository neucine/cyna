import std.io;
import std.fs;
import { IoError } from std.io;

fn run(): i32 ! IoError {
    var output = fs.stdout();
    try io.write_all(&output, "stdout byte stream\n".bytes());
    try output.flush();

    var errors = fs.stderr();
    try io.write_all(&errors, "stderr byte stream\n".bytes());
    try errors.flush();
    return 42;
}

fn main(): i32 {
    return run() catch (code) {
        return 99;
    };
}

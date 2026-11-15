const build = @import("build.zig");
const help = @import("help.zig");
const test_command = @import("test_command.zig");

test {
    _ = build;
    _ = help;
    _ = test_command;
}

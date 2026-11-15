const std = @import("std");
const cyna = @import("cyna");

const helpers = @import("../helpers.zig");

test "build help exits cleanly" {
    try helpers.expectStderrContains(cyna.help.build_usage, "usage: cyna build");
    try std.testing.expect(std.mem.indexOf(u8, cyna.help.build_usage, "--emit-c-header") != null);
}

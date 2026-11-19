const std = @import("std");
const helpers = @import("../helpers.zig");

test "native std.fs standard stream writers" {
    try helpers.expectNativeSourceExitCode(
        std.testing.allocator,
        "native_hosted_io.cy",
        @embedFile("hosted_io_fixture.cy"),
        42,
    );
}

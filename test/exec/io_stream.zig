const std = @import("std");
const helpers = @import("../helpers.zig");

test "native std.io byte stream helpers" {
    try helpers.expectNativeSourceExitCode(
        std.testing.allocator,
        "native_std_io_stream.cy",
        @embedFile("io_stream_fixture.cy"),
        42,
    );
}

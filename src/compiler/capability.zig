const std = @import("std");

pub const Error = error{
    BackendPackedAggregateTooWide,
    BackendPackedFieldAddressUnsupported,
};

pub fn message(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.BackendPackedAggregateTooWide => "backend capability unavailable: packed aggregate exceeds the 65535-bit lowering limit",
        error.BackendPackedFieldAddressUnsupported => "LLVM backend capability unavailable: packed aggregate fields cannot be addressed independently",
        else => null,
    };
}

test "capability errors have stable actionable messages" {
    try std.testing.expectEqualStrings(
        "backend capability unavailable: packed aggregate exceeds the 65535-bit lowering limit",
        message(error.BackendPackedAggregateTooWide).?,
    );
    try std.testing.expectEqualStrings(
        "LLVM backend capability unavailable: packed aggregate fields cannot be addressed independently",
        message(error.BackendPackedFieldAddressUnsupported).?,
    );
    try std.testing.expect(message(error.OutOfMemory) == null);
}

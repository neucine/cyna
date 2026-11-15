const std = @import("std");

pub const result_type_name = "result";

/// Source-level cases of the built-in result type. Text is resolved once at
/// the semantic boundary; downstream compiler stages carry this identity.
pub const ResultCase = enum {
    ok,
    err,

    pub fn sourceName(self: ResultCase) []const u8 {
        return switch (self) {
            .ok => "ok",
            .err => "err",
        };
    }
};

pub fn resolveResultCase(name: []const u8) ?ResultCase {
    if (std.mem.eql(u8, name, ResultCase.ok.sourceName())) return .ok;
    if (std.mem.eql(u8, name, ResultCase.err.sourceName())) return .err;
    return null;
}

test "result case spellings resolve only at the language boundary" {
    try std.testing.expectEqual(ResultCase.ok, resolveResultCase("ok").?);
    try std.testing.expectEqual(ResultCase.err, resolveResultCase("err").?);
    try std.testing.expect(resolveResultCase("success") == null);
}

const std = @import("std");
const compat = @import("cyna").compat;

test "canonical documentation examples do not use removed let declarations" {
    for ([_][]const u8{
        "docs/SPEC.md",
        "docs/SEMANTICS.md",
        "docs/CONCURRENCY.md",
    }) |path| {
        const document = try compat.readFileAlloc(std.testing.allocator, path, 1 << 20);
        defer std.testing.allocator.free(document);
        try std.testing.expect(std.mem.indexOf(u8, document, "\nlet ") == null);
        try std.testing.expect(std.mem.indexOf(u8, document, "\n    let ") == null);
        try std.testing.expect(std.mem.indexOf(u8, document, "\n    .ctx =") == null);
    }
}

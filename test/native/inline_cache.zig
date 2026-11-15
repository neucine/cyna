const std = @import("std");
const cyna = @import("cyna");

test "inline tests reuse one cached LLVM root object" {
    const llvm_ir =
        \\%cyna_inline_trace = type { ptr, i32, i32 }
        \\
        \\%cyna_inline_result = type { i8, i8, i64, %cyna_inline_trace }
        \\
        \\define void @cyna_test_one(ptr sret(%cyna_inline_result) %out) {
        \\entry:
        \\  store %cyna_inline_result zeroinitializer, ptr %out
        \\  ret void
        \\}
        \\
        \\define void @cyna_test_two(ptr sret(%cyna_inline_result) %out) {
        \\entry:
        \\  store %cyna_inline_result zeroinitializer, ptr %out
        \\  ret void
        \\}
        \\
        \\define void @cyna_test_failure(ptr sret(%cyna_inline_result) %out) {
        \\entry:
        \\  store %cyna_inline_result { i8 1, i8 0, i64 0, %cyna_inline_trace zeroinitializer }, ptr %out
        \\  ret void
        \\}
        \\
    ;
    const target = cyna.build_pkg.model.BuildTarget{
        .is_project = false,
        .display_path = "inline-cache.test.cy",
        .root_dir = ".",
        .source_path = "inline-cache.test.cy",
        .name = "inline-cache",
    };
    var results: [3]?anyerror = undefined;
    var durations: [3]u64 = undefined;
    try cyna.build_pkg.native.compileAndRunInlineTests(
        std.testing.allocator,
        llvm_ir,
        .{},
        target,
        &.{ "cyna_test_one", "cyna_test_two", "cyna_test_failure" },
        &results,
        &durations,
    );
    try std.testing.expect(results[0] == null);
    try std.testing.expect(results[1] == null);
    try std.testing.expect(results[2].? == error.TestFailed);
    try std.testing.expect(durations[0] != 0);
    try std.testing.expect(durations[1] != 0);
    try std.testing.expect(durations[2] != 0);
}

const std = @import("std");
const parity = @import("targets.zig");

test "failure traces emit bounded runtime calls on freestanding targets" {
    const source =
        \\enum Failure { bad; }
        \\fn fail(): i32!Failure { throw Failure.bad, "detail"; }
        \\fn pass(): i32!Failure { return try fail(); }
        \\fn main(): i32 {
        \\    return pass() catch (code, failure) {
        \\        if failure.available { yield failure.origin as i32; }
        \\        yield 0;
        \\    };
        \\}
    ;
    for (parity.freestanding_64) |target| {
        const llvm = try parity.emitLlvm(std.testing.allocator, "failure_trace", source, target);
        defer std.testing.allocator.free(llvm);
        try parity.expectLlvmContains(llvm, "cyna_trace_create_location_abi");
        try parity.expectLlvmContains(llvm, "cyna_trace_append_location_abi");
        try parity.expectLlvmContains(llvm, "cyna_trace_available_abi");
        try parity.expectLlvmContains(llvm, "cyna_trace_release_abi");
    }
}

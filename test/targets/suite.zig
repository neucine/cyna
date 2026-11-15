const c_abi = @import("c_abi.zig");
const failure_trace = @import("failure_trace.zig");
const targets = @import("targets.zig");

test {
    _ = c_abi;
    _ = failure_trace;
    _ = targets;
}

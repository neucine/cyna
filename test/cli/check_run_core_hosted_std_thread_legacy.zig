const check_run_core_hosted_std_thread_accept_legacy = @import("check_run_core_hosted_std_thread_accept_legacy.zig");
const check_run_core_hosted_std_thread_bridge_legacy = @import("check_run_core_hosted_std_thread_bridge_legacy.zig");
const check_run_core_hosted_std_thread_raw_legacy = @import("check_run_core_hosted_std_thread_raw_legacy.zig");

test {
    _ = check_run_core_hosted_std_thread_accept_legacy;
    _ = check_run_core_hosted_std_thread_bridge_legacy;
    _ = check_run_core_hosted_std_thread_raw_legacy;
}

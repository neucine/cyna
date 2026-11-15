const check_run_core_hosted_std_sync_accept_legacy = @import("cli/check_run_core_hosted_std_sync_accept_legacy.zig");
const check_run_core_hosted_std_sync_bridge_legacy = @import("cli/check_run_core_hosted_std_sync_bridge_legacy.zig");
const check_run_core_hosted_std_sync_raw_legacy = @import("cli/check_run_core_hosted_std_sync_raw_legacy.zig");

test {
    _ = check_run_core_hosted_std_sync_accept_legacy;
    _ = check_run_core_hosted_std_sync_bridge_legacy;
    _ = check_run_core_hosted_std_sync_raw_legacy;
}

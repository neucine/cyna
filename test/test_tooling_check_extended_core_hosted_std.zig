const check_run_core_hosted_std_fs_legacy = @import("cli/check_run_core_hosted_std_fs_legacy.zig");
const check_run_core_hosted_std_thread_legacy = @import("cli/check_run_core_hosted_std_thread_legacy.zig");
const check_run_core_hosted_std_sync_legacy = @import("cli/check_run_core_hosted_std_sync_legacy.zig");

test {
    _ = check_run_core_hosted_std_fs_legacy;
    _ = check_run_core_hosted_std_thread_legacy;
    _ = check_run_core_hosted_std_sync_legacy;
}

const check_run_native_std_fs_legacy = @import("cli/check_run_native_std_fs_legacy.zig");
const check_run_native_std_process_legacy = @import("cli/check_run_native_std_process_legacy.zig");
const check_run_native_std_path_time_legacy = @import("cli/check_run_native_std_path_time_legacy.zig");
const check_run_native_std_thread_sync_legacy = @import("cli/check_run_native_std_thread_sync_legacy.zig");

test {
    _ = check_run_native_std_fs_legacy;
    _ = check_run_native_std_process_legacy;
    _ = check_run_native_std_path_time_legacy;
    _ = check_run_native_std_thread_sync_legacy;
}

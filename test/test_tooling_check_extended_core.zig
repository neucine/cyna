const check_run_core_basic_legacy = @import("cli/check_run_core_basic_legacy.zig");
const check_run_core_hosted_std_legacy = @import("cli/check_run_core_hosted_std_legacy.zig");
const check_run_core_prelude_legacy = @import("cli/check_run_core_prelude_legacy.zig");
const check_run_core_emit_alias_legacy = @import("cli/check_run_core_emit_alias_legacy.zig");

test {
    _ = check_run_core_basic_legacy;
    _ = check_run_core_hosted_std_legacy;
    _ = check_run_core_prelude_legacy;
    _ = check_run_core_emit_alias_legacy;
}

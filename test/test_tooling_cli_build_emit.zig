const build_emit_stage_legacy = @import("cli/build_emit_stage_legacy.zig");
const build_emit_asm_legacy = @import("cli/build_emit_asm_legacy.zig");
const build_emit_module_ll_legacy = @import("cli/build_emit_module_ll_legacy.zig");
const build_emit_obj_legacy = @import("cli/build_emit_obj_legacy.zig");
const build_emit_header_legacy = @import("cli/build_emit_header_legacy.zig");

test {
    _ = build_emit_stage_legacy;
    _ = build_emit_asm_legacy;
    _ = build_emit_module_ll_legacy;
    _ = build_emit_obj_legacy;
    _ = build_emit_header_legacy;
}

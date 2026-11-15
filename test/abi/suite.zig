const backend_llvm_c_abi = @import("../backend/llvm/c_abi.zig");
const exec_c_abi = @import("../exec/c_abi.zig");
const lower_alignment = @import("../lower/alignment.zig");
const lower_c_abi = @import("../lower/c_abi.zig");
const sema_c_abi = @import("../sema/c_abi.zig");
const surface_c_abi = @import("../surface/c_abi.zig");
const targets_c_abi = @import("../targets/c_abi.zig");
const targets_matrix = @import("../targets/targets.zig");

test {
    _ = backend_llvm_c_abi;
    _ = exec_c_abi;
    _ = lower_alignment;
    _ = lower_c_abi;
    _ = sema_c_abi;
    _ = surface_c_abi;
    _ = targets_c_abi;
    _ = targets_matrix;
}

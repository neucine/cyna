const c_abi = @import("c_abi.zig");
const core = @import("core.zig");
const equality = @import("equality.zig");
const examples = @import("examples.zig");
const hal_arch = @import("hal_arch.zig");
const io = @import("io.zig");
const literals = @import("literals.zig");
const numeric = @import("numeric.zig");
const packed_tests = @import("packed.zig");
const refs_projection = @import("refs_projection.zig");
const slices = @import("slices.zig");
const storage = @import("storage.zig");
const strings = @import("strings.zig");

test {
    _ = c_abi;
    _ = core;
    _ = equality;
    _ = examples;
    _ = hal_arch;
    _ = io;
    _ = literals;
    _ = numeric;
    _ = packed_tests;
    _ = refs_projection;
    _ = slices;
    _ = storage;
    _ = strings;
}

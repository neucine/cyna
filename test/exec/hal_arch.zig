const std = @import("std");
const helpers = @import("../helpers.zig");

test "mmio register wrapper supports typed and raw volatile access" {
    const source =
        \\import embedded.hal.mmio;
        \\
        \\packed struct Status {
        \\    ready: u1;
        \\    mode: u3;
        \\    error: u4;
        \\}
        \\
        \\fn main(): i32 {
        \\    var status = new Status { ready: 0, mode: 0, error: 0 };
        \\    const ptr: *Status = status.ptr();
        \\    unchecked {
        \\        const raw = ptr as! usize;
        \\        const reg = mmio.reg<Status, u8>(raw);
        \\        reg.write(Status { ready: 1, mode: 2, error: 3 });
        \\        if reg.read().mode != 2 {
        \\            return 1;
        \\        }
        \\        reg.write_raw(53 as u8);
        \\        if reg.read_raw() != (53 as u8) {
        \\            return 2;
        \\        }
        \\        if reg.read().mode != 2 {
        \\            return 3;
        \\        }
        \\        reg.modify_raw(0xf1 as u8, 0x0c as u8);
        \\        if reg.read().mode != 6 {
        \\            return 4;
        \\        }
        \\        const desired: u3 = 5;
        \\        reg.modify(|value| {
        \\            value.mode = desired;
        \\        });
        \\        if reg.read().mode != 5 {
        \\            return 5;
        \\        }
        \\    }
        \\    return 42;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "mmio_register_typed_raw_access", "native_mmio_register_typed_raw_access.cy", source, 42);
}

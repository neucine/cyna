const std = @import("std");
const helpers = @import("../helpers.zig");

test "embedded hal and arch modules are importable" {
    const source =
        \\import embedded.hal;
        \\import embedded.hal.gpio;
        \\import embedded.hal.uart;
        \\import embedded.hal.mmio;
        \\import embedded.arch;
        \\import { InterruptState } from embedded.arch;
        \\import embedded.arch.barrier;
        \\import embedded.arch.cpu;
        \\
        \\fn main(): i32 {
        \\    const state = InterruptState { raw: 42 };
        \\    return state.raw as i32;
        \\}
    ;

    try helpers.expectLoadedSemanticSuccessWithOptions(std.testing.allocator, "embedded_hal_arch_importable", source, .{ .target = "riscv32-none-elf" });
}

test "uart protocol can be implemented by a platform type" {
    const source =
        \\import { HalError } from embedded.hal;
        \\import { ByteWrite, ByteFlush, UartWrite } from embedded.hal.uart;
        \\
        \\struct PlatformUart {
        \\    count: u8;
        \\}
        \\
        \\impl PlatformUart: ByteWrite {
        \\    fn write_byte(self: &PlatformUart, byte: u8): void!HalError {
        \\        self.count = byte;
        \\        return;
        \\    }
        \\}
        \\
        \\impl PlatformUart: ByteFlush {
        \\    fn flush(self: &PlatformUart): void!HalError {
        \\        return;
        \\    }
        \\}
        \\
        \\impl PlatformUart: UartWrite {
        \\    fn write_byte(self: &PlatformUart, byte: u8): void!HalError {
        \\        self.count = byte;
        \\        return;
        \\    }
        \\
        \\    fn flush(self: &PlatformUart): void!HalError {
        \\        return;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectLoadedSemanticSuccessWithOptions(std.testing.allocator, "embedded_hal_uart_protocol_impl", source, .{ .target = "riscv32-none-elf" });
}

test "gpio protocols support pin state and readable output contracts" {
    const source =
        \\import { HalError } from embedded.hal;
        \\import { InputPin, OutputPin, PinState, StatefulOutputPin, ToggleOutputPin } from embedded.hal.gpio;
        \\
        \\struct LedPin {
        \\    high: bool;
        \\}
        \\
        \\impl LedPin: OutputPin {
        \\    fn set_high(self: &LedPin): void!HalError {
        \\        self.high = true;
        \\        return;
        \\    }
        \\
        \\    fn set_low(self: &LedPin): void!HalError {
        \\        self.high = false;
        \\        return;
        \\    }
        \\
        \\    fn set_state(self: &LedPin, state: PinState): void!HalError {
        \\        self.high = state == PinState.high;
        \\        return;
        \\    }
        \\}
        \\
        \\impl LedPin: InputPin {
        \\    fn is_high(self: &LedPin): bool!HalError {
        \\        return self.high;
        \\    }
        \\
        \\    fn is_low(self: &LedPin): bool!HalError {
        \\        return not self.high;
        \\    }
        \\}
        \\
        \\impl LedPin: StatefulOutputPin {
        \\    fn is_set_high(self: &LedPin): bool!HalError {
        \\        return self.high;
        \\    }
        \\
        \\    fn is_set_low(self: &LedPin): bool!HalError {
        \\        return not self.high;
        \\    }
        \\}
        \\
        \\impl LedPin: ToggleOutputPin {
        \\    fn toggle(self: &LedPin): void!HalError {
        \\        self.high = not self.high;
        \\        return;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectLoadedSemanticSuccessWithOptions(std.testing.allocator, "embedded_hal_gpio_pin_contracts", source, .{ .target = "riscv32-none-elf" });
}

test "mmio register wrappers support generated register shapes" {
    const source =
        \\import embedded.hal.mmio;
        \\
        \\packed struct TxData {
        \\    data: u8;
        \\    reserved0: u23;
        \\    full: u1;
        \\}
        \\
        \\struct Uart0 {
        \\    txdata: mmio.Reg<TxData, u32>;
        \\
        \\    fn at(base: usize): Uart0 {
        \\        return Uart0 {
        \\            txdata: mmio.reg<TxData, u32>(base + 0),
        \\        };
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const uart = Uart0.at(0x10013000);
        \\    const byte: u8 = 42;
        \\    uart.txdata.modify(|tx| {
        \\        tx.data = byte;
        \\    });
        \\    if (uart.txdata.addr != 0) {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectLoadedSemanticSuccessWithOptions(std.testing.allocator, "embedded_hal_mmio_generated_shape", source, .{ .target = "riscv32-none-elf" });
}

test "nested register structs can be used through type qualification" {
    const source =
        \\import embedded.hal.mmio;
        \\
        \\struct Uart0 {
        \\    pub packed struct Txdata {
        \\        pub data: u8;
        \\        pub reserved0: u23;
        \\        pub full: u1;
        \\    }
        \\
        \\    pub txdata: mmio.Reg<Uart0.Txdata, u32>;
        \\}
        \\
        \\fn main(): i32 {
        \\    const uart = Uart0 { txdata: mmio.reg<Uart0.Txdata, u32>(0x10013000) };
        \\    if (uart.txdata.addr != 0) {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectLoadedSemanticSuccessWithOptions(std.testing.allocator, "nested_register_structs_type_qualification", source, .{ .target = "riscv32-none-elf" });
}

test "unambiguous nested register structs can use short type names" {
    const source =
        \\import embedded.hal.mmio;
        \\
        \\struct Uart0 {
        \\    pub packed struct Txdata {
        \\        pub data: u8;
        \\        pub reserved0: u23;
        \\        pub full: u1;
        \\    }
        \\
        \\    pub txdata: mmio.Reg<Txdata, u32>;
        \\}
        \\
        \\fn main(): i32 {
        \\    const uart = Uart0 { txdata: mmio.reg<Txdata, u32>(0x10013000) };
        \\    if (uart.txdata.addr != 0) {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectLoadedSemanticSuccessWithOptions(std.testing.allocator, "nested_register_structs_short_type_name", source, .{ .target = "riscv32-none-elf" });
}

test "ambiguous nested register struct short type names report candidates" {
    const source =
        \\struct Uart0 {
        \\    packed struct Txdata {
        \\        data: u8;
        \\    }
        \\}
        \\
        \\struct Uart1 {
        \\    packed struct Txdata {
        \\        data: u8;
        \\    }
        \\}
        \\
        \\struct Device {
        \\    txdata: Txdata;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "nested_register_structs_ambiguous_short_type_name",
        source,
        "ambiguous type name `Txdata`; candidates are",
    );
}

test "struct namespace constants are static members" {
    const source =
        \\struct device {
        \\    pub const reg0: u32 = 10;
        \\    pub const regs: [2]u32 = [device.reg0, 20];
        \\}
        \\
        \\const device_reg0: u32 = 99;
        \\
        \\fn main(): i32 {
        \\    return (device.regs[0] + device_reg0) as i32;
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "struct_namespace_constants_static_members", source);
}

test "generated fe310 soc module is importable" {
    const source =
        \\import embedded.soc.sifive.fe310;
        \\
        \\fn main(): i32 {
        \\    if ((fe310.uart0.txdata.addr != 0) and (fe310.pmu.pmuwakepm[0].addr != 0)) {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectLoadedSemanticSuccessWithOptions(std.testing.allocator, "embedded_soc_fe310_importable", source, .{
        .target = "riscv32-none-elf",
    });
}

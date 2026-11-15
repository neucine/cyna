pub enum HalError: i32 {
    unsupported = 0,
    busy,
    timeout,
    invalid_config,
    bus,
    arbitration_lost,
    no_ack,
    overrun,
    underrun,
}

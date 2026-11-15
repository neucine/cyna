import embedded.hal;

pub protocol ByteWrite {
    fn write_byte(self: &Self, byte: u8): void ! hal.HalError;
}

pub protocol ByteRead {
    fn read_byte(self: &Self): u8 ! hal.HalError;
}

pub protocol ByteFlush {
    fn flush(self: &Self): void ! hal.HalError;
}

pub protocol ByteWriteReady {
    fn can_write(self: &Self): bool ! hal.HalError;
}

pub protocol ByteReadReady {
    fn can_read(self: &Self): bool ! hal.HalError;
}

pub protocol UartWrite {
    fn write_byte(self: &Self, byte: u8): void ! hal.HalError;
    fn flush(self: &Self): void ! hal.HalError;
}

pub protocol UartRead {
    fn read_byte(self: &Self): u8 ! hal.HalError;
}

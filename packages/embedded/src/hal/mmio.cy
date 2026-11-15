pub struct Reg<T, Raw> {
    pub addr: usize;

    pub fn raw_ptr(self: Reg<T, Raw>): *volatile Raw {
        unchecked {
            return self.addr as! *volatile Raw;
        }
    }

    pub fn typed_ptr(self: Reg<T, Raw>): *volatile T {
        unchecked {
            return self.addr as! *volatile T;
        }
    }

    pub fn read_raw(self: Reg<T, Raw>): Raw {
        unchecked {
            return *self.raw_ptr();
        }
    }

    pub fn write_raw(self: Reg<T, Raw>, value: Raw): void {
        unchecked {
            const ptr = self.raw_ptr();
            *ptr = value;
        }
    }

    pub fn read(self: Reg<T, Raw>): T {
        unchecked {
            return *self.typed_ptr();
        }
    }

    pub fn write(self: Reg<T, Raw>, value: T): void {
        unchecked {
            const ptr = self.typed_ptr();
            *ptr = value;
        }
    }

    pub fn modify(self: Reg<T, Raw>, patch: (&T) => void): void {
        var value = self.read();
        patch(&value);
        self.write(value);
    }

    pub fn modify_raw(self: Reg<T, Raw>, preserve_mask: Raw, set_bits: Raw): void {
        const value = (self.read_raw() & preserve_mask) | set_bits;
        self.write_raw(value);
    }

    pub fn write_raw_masked(self: Reg<T, Raw>, preserve_mask: Raw, set_bits: Raw): void {
        self.modify_raw(preserve_mask, set_bits);
    }

    pub fn set_raw_bits(self: Reg<T, Raw>, mask: Raw): void {
        self.write_raw(self.read_raw() | mask);
    }
}

pub fn reg<T, Raw>(addr: usize): Reg<T, Raw> {
    return Reg<T, Raw> {
        addr: addr
    };
}

pub fn reg32<T>(addr: usize): Reg<T, u32> {
    return reg<T, u32>(addr);
}

pub fn reg64<T>(addr: usize): Reg<T, u64> {
    return reg<T, u64>(addr);
}

pub type Reg32<T> = Reg<T, u32>;
pub type Reg64<T> = Reg<T, u64>;

pub struct ReadOnlyReg<T, Raw> {
    pub addr: usize;

    pub fn raw_ptr(self: ReadOnlyReg<T, Raw>): *volatile Raw {
        unchecked {
            return self.addr as! *volatile Raw;
        }
    }

    pub fn typed_ptr(self: ReadOnlyReg<T, Raw>): *volatile T {
        unchecked {
            return self.addr as! *volatile T;
        }
    }

    pub fn read_raw(self: ReadOnlyReg<T, Raw>): Raw {
        unchecked {
            return *self.raw_ptr();
        }
    }

    pub fn read(self: ReadOnlyReg<T, Raw>): T {
        unchecked {
            return *self.typed_ptr();
        }
    }
}

pub fn read_only<T, Raw>(addr: usize): ReadOnlyReg<T, Raw> {
    return ReadOnlyReg<T, Raw> {
        addr: addr
    };
}

pub fn reg32_ro<T>(addr: usize): ReadOnlyReg<T, u32> {
    return read_only<T, u32>(addr);
}

pub fn reg64_ro<T>(addr: usize): ReadOnlyReg<T, u64> {
    return read_only<T, u64>(addr);
}

pub type Reg32RO<T> = ReadOnlyReg<T, u32>;
pub type Reg64RO<T> = ReadOnlyReg<T, u64>;

pub struct WriteOnlyReg<T, Raw> {
    pub addr: usize;

    pub fn raw_ptr(self: WriteOnlyReg<T, Raw>): *volatile Raw {
        unchecked {
            return self.addr as! *volatile Raw;
        }
    }

    pub fn typed_ptr(self: WriteOnlyReg<T, Raw>): *volatile T {
        unchecked {
            return self.addr as! *volatile T;
        }
    }

    pub fn write_raw(self: WriteOnlyReg<T, Raw>, value: Raw): void {
        unchecked {
            const ptr = self.raw_ptr();
            *ptr = value;
        }
    }

    pub fn write(self: WriteOnlyReg<T, Raw>, value: T): void {
        unchecked {
            const ptr = self.typed_ptr();
            *ptr = value;
        }
    }
}

pub fn write_only<T, Raw>(addr: usize): WriteOnlyReg<T, Raw> {
    return WriteOnlyReg<T, Raw> {
        addr: addr
    };
}

pub fn reg32_wo<T>(addr: usize): WriteOnlyReg<T, u32> {
    return write_only<T, u32>(addr);
}

pub fn reg64_wo<T>(addr: usize): WriteOnlyReg<T, u64> {
    return write_only<T, u64>(addr);
}

pub type Reg32WO<T> = WriteOnlyReg<T, u32>;
pub type Reg64WO<T> = WriteOnlyReg<T, u64>;

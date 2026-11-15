pub type WriterWriteFn = c fn (*c_char, c_llong, ?*c_void): void;

pub extern c fn install_writer(write_fn: WriterWriteFn, ctx: ?*c_void): void;
pub extern c fn clear_writer(): void;

pub fn write_string(value: string): void {
    print(value);
}

pub fn write_line(value: string): void {
    println(value);
}

pub fn relax(): void {
    unchecked {
        asm volatile {
            "";
            clobber memory;
        }
    }
}

pub fn halt(): void {
    relax();
}

pub fn wait_for_interrupt(): void {
    relax();
}

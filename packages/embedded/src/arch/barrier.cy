pub fn compiler_fence(): void {
    unchecked {
        asm volatile {
            "";
            clobber memory;
        }
    }
}

pub fn memory_fence(): void {
    compiler_fence();
}

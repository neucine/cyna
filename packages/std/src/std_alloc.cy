pub c struct RootAllocator {
    pub ctx: *c_void;
    pub alloc_fn: c fn (*c_void, c_size_t): *c_void;
    pub realloc_fn: c fn (*c_void, *c_void, c_size_t): *c_void;
    pub free_fn: c fn (*c_void, *c_void): void;
}

pub extern c fn install_root_allocator(allocator: RootAllocator): void;
pub extern c fn init_bump_root(heap: []u8): void;
pub extern c fn clear_root(): void;
pub extern c fn has_root(): bool;

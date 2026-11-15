import std.alloc as rt_alloc;
import { RootAllocator } from std.alloc;

extern c("malloc") fn malloc(size: c_size_t): *c_void;
extern c("realloc") fn realloc(ptr: *c_void, size: c_size_t): *c_void;
extern c("free") fn free(ptr: *c_void): void;

export c("host_alloc") fn host_alloc(_ctx: *c_void, size: c_size_t): *c_void {
    return malloc(size);
}

export c("host_realloc") fn host_realloc(_ctx: *c_void, ptr: *c_void, size: c_size_t): *c_void {
    return realloc(ptr, size);
}

export c("host_free") fn host_free(_ctx: *c_void, ptr: *c_void): void {
    free(ptr);
}

fn main(): i32 {
    const allocator = RootAllocator {
        ctx: 0 as! *c_void,
        alloc_fn: host_alloc,
        realloc_fn: host_realloc,
        free_fn: host_free,
    };
    rt_alloc.install_root_allocator(allocator);

    var xs: List<i32> = list<i32>();
    xs.push(40);
    xs.push(2);
    if xs.len() == 2 and xs[0] + xs[1] == 42 {
        return 0;
    }
    return 1;
}

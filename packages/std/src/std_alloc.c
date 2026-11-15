#include "../../../src/runtime/cyna.h"

void cyna_runtime_install_root_allocator(CynaAllocator allocator);
void cyna_runtime_init_bump_root_allocator(void *start, size_t size);
void cyna_runtime_clear_root_allocator(void);
uint8_t cyna_runtime_has_root_allocator(void);

void cyna_std_alloc_install_root_allocator(CynaAllocator allocator) {
    cyna_runtime_install_root_allocator(allocator);
}

void cyna_std_alloc_init_bump_root(CynaBytes heap) {
    cyna_runtime_init_bump_root_allocator(heap.ptr, (size_t)heap.len);
}

void cyna_std_alloc_clear_root(void) {
    cyna_runtime_clear_root_allocator();
}

_Bool cyna_std_alloc_has_root(void) {
    return cyna_runtime_has_root_allocator() ? 1 : 0;
}

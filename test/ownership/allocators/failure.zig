const std = @import("std");

const test_exec = @import("../../support.zig");

test "root allocator failure aborts instead of producing a nullable allocation" {
    const llvm_ir =
        \\declare ptr @cyna_runtime_tracked_alloc(i64)
        \\declare void @cyna_test_install_failing_allocator()
        \\
        \\define i64 @main() {
        \\entry:
        \\  call void @cyna_test_install_failing_allocator()
        \\  %ptr = call ptr @cyna_runtime_tracked_alloc(i64 8)
        \\  ret i64 99
        \\}
    ;

    const allocator_helper_source =
        \\#include <stddef.h>
        \\
        \\typedef void *(*CynaAllocatorAllocFn)(void *ctx, size_t size);
        \\typedef void *(*CynaAllocatorReallocFn)(void *ctx, void *ptr, size_t size);
        \\typedef void (*CynaAllocatorFreeFn)(void *ctx, void *ptr);
        \\
        \\typedef struct {
        \\    void *ctx;
        \\    CynaAllocatorAllocFn alloc;
        \\    CynaAllocatorReallocFn realloc;
        \\    CynaAllocatorFreeFn free;
        \\} CynaAllocator;
        \\
        \\extern void cyna_runtime_install_root_allocator(CynaAllocator allocator);
        \\
        \\static void *fail_alloc(void *ctx, size_t size) {
        \\    (void)ctx;
        \\    (void)size;
        \\    return NULL;
        \\}
        \\
        \\static void *fail_realloc(void *ctx, void *ptr, size_t size) {
        \\    (void)ctx;
        \\    (void)ptr;
        \\    (void)size;
        \\    return NULL;
        \\}
        \\
        \\static void ignore_free(void *ctx, void *ptr) {
        \\    (void)ctx;
        \\    (void)ptr;
        \\}
        \\
        \\void cyna_test_install_failing_allocator(void) {
        \\    cyna_runtime_install_root_allocator((CynaAllocator){
        \\        .ctx = NULL,
        \\        .alloc = fail_alloc,
        \\        .realloc = fail_realloc,
        \\        .free = ignore_free,
        \\    });
        \\}
    ;

    const outcome = try test_exec.compileAndRunNativeIrOutcomeWithCSources(
        std.testing.allocator,
        llvm_ir,
        .{ .runtime = true },
        &.{.{
            .name = "failing_allocator_test.c",
            .source = allocator_helper_source,
        }},
    );
    try std.testing.expect(!outcome.succeeded());
}

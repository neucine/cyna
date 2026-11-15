// Exhaustive allocation-failure tests run in a separate lane because each
// case recompiles the source once for every allocation point.
const cyna = @import("cyna");
const allocation_failures = @import("sema/context_allocation_failures.zig");

test {
    _ = cyna.compiler.sema;
    _ = allocation_failures;
}

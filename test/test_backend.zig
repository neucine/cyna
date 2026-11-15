const cyna = @import("cyna");
const backend_suite = @import("backend/suite.zig");

test {
    _ = cyna.llvm_backend;
    _ = backend_suite;
}

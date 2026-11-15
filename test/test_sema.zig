const cyna = @import("cyna");
const sema_suite = @import("sema/suite.zig");

test {
    _ = cyna.compiler.sema;
    _ = sema_suite;
}

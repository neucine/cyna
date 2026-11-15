const cyna = @import("cyna");
const test_suite = @import("suite.zig");

test {
    _ = cyna.cli;
    _ = cyna.commands.build;
    _ = cyna.commands.install;
    _ = cyna.commands.package;
    _ = cyna.toolchain_support;
    _ = cyna.build_pkg.native;
    _ = cyna.build_pkg.build_cache;
    _ = test_suite;
}

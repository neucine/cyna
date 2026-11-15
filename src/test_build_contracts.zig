// Internal build tests need a root in this module: importing the public cyna
// dependency from test/test.zig does not discover its test declarations.
test {
    _ = @import("build/cache_bundle.zig");
    _ = @import("build/llvm_cache_entry.zig");
    _ = @import("distribution_paths.zig");
    _ = @import("build/build_cache.zig");
    _ = @import("build/toolchain.zig");
    _ = @import("commands/module_build.zig");
}

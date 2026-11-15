const std = @import("std");
const compat = @import("cyna").compat;

const compiler = @import("cyna").compiler;
const diagnostics = compiler.diagnostics;
const helpers = @import("../helpers.zig");
const loader = compiler.loader;
const sema = compiler.sema;

test "module import resolves through namespace across files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/math.cy", .data =
        \\
        \\pub fn forty_two(): i32 {
        \\    return 42;
        \\}
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import lib.math;
        \\
        \\fn main(): i32 {
        \\    return math.forty_two();
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);

    try helpers.expectNativeFileExitCode(std.testing.allocator, root_path, 42);
}

test "module namespace value access has specific diagnostic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/config.cy", .data =
        \\
        \\pub const answer: i32 = 42;
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import lib.config;
        \\
        \\fn main(): i32 {
        \\    return config.missing;
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);

    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const scratch_allocator = scratch.allocator();
    var loaded = try loader.loadProgram(scratch_allocator, root_path);
    defer loaded.deinit(scratch_allocator);

    var sink = diagnostics.Sink.init(std.testing.allocator);
    defer sink.deinit();
    const diagnostic_context = diagnostics.Context.structured(&sink);

    try std.testing.expectError(error.SemanticFailed, sema.buildSirWithOptions(scratch_allocator, root_path, loaded.program, .{
        .diagnostic_context = diagnostic_context,
    }));
    try helpers.expectDiagnosticContains(&sink, "module namespace `config` cannot be used as a value");
    try helpers.expectDiagnosticContains(&sink, "module `lib.config` has no public compile-time constant `missing`");
    try helpers.expectDiagnosticNotContains(&sink, "unknown value `config`");
}

test "module namespace resolves public constants across files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/config.cy", .data =
        \\
        \\pub const base: i32 = 40;
        \\pub const answer: i32 = base + 2;
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import lib.config;
        \\
        \\fn main(): i32 {
        \\    return config.answer;
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);

    try helpers.expectNativeFileExitCode(std.testing.allocator, root_path, 42);
}

test "module namespace public constants can initialize constants" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/platform.cy", .data =
        \\
        \\pub const page_size: i32 = 4096;
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/layout.cy", .data =
        \\import lib.platform;
        \\
        \\pub const page_size: i32 = platform.page_size;
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import lib.layout;
        \\
        \\fn main(): i32 {
        \\    return layout.page_size / 1024 + 38;
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);

    try helpers.expectNativeFileExitCode(std.testing.allocator, root_path, 42);
}

test "same-module const initializers ignore duplicate basenames in other modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "kernel/memory");
    try compat.dirMakePath(tmp.dir, "platform");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "kernel/memory/phys.cy", .data =
        \\pub var ram_start: usize = 0;
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "platform/memory.cy", .data =
        \\pub const ram_start: usize = 0x40000000;
        \\pub const ram_size: usize = 0x08000000;
        \\pub const ram_end: usize = ram_start + ram_size;
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import kernel.memory.phys;
        \\import platform.memory;
        \\
        \\fn main(): i32 {
        \\    if memory.ram_end == 0x48000000 {
        \\        return 42;
        \\    }
        \\    return 1;
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);

    try helpers.expectNativeFileExitCode(std.testing.allocator, root_path, 42);
}

test "same-module global value access ignores duplicate basenames in other modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "other");
    try compat.dirMakePath(tmp.dir, "app");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "other/state.cy", .data =
        \\pub var answer: i32 = 1;
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "app/main_mod.cy", .data =
        \\pub const answer: i32 = 42;
        \\
        \\pub fn read(): i32 {
        \\    return answer;
        \\}
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import other.state;
        \\import app.main_mod;
        \\
        \\fn main(): i32 {
        \\    return main_mod.read();
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);

    try helpers.expectNativeFileExitCode(std.testing.allocator, root_path, 42);
}

test "selected import resolves across files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/math.cy", .data =
        \\
        \\pub fn forty_two(): i32 {
        \\    return 42;
        \\}
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import { forty_two } from lib.math;
        \\
        \\fn main(): i32 {
        \\    return forty_two();
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);

    try helpers.expectNativeFileExitCode(std.testing.allocator, root_path, 42);
}

test "same top-level function name in different modules gets unique symbols" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "drivers");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "drivers/uart.cy", .data =
        \\pub fn init(): i32 {
        \\    return 10;
        \\}
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "drivers/timer.cy", .data =
        \\pub fn init(): i32 {
        \\    return 32;
        \\}
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import drivers.uart;
        \\import drivers.timer;
        \\
        \\fn main(): i32 {
        \\    return uart.init() + timer.init();
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);

    try helpers.expectNativeFileExitCode(std.testing.allocator, root_path, 42);
}

test "root-package import resolves through namespace across files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/math.cy", .data =
        \\
        \\pub fn forty_two(): i32 {
        \\    return 42;
        \\}
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import .lib.math;
        \\
        \\fn main(): i32 {
        \\    return math.forty_two();
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);

    try helpers.expectNativeFileExitCode(std.testing.allocator, root_path, 42);
}

test "selected root-package import resolves across files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/math.cy", .data =
        \\
        \\pub fn forty_two(): i32 {
        \\    return 42;
        \\}
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import { forty_two } from .lib.math;
        \\
        \\fn main(): i32 {
        \\    return forty_two();
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);

    try helpers.expectNativeFileExitCode(std.testing.allocator, root_path, 42);
}

test "root-package import does not resolve builtin std package" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "std");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "std/fs.cy", .data =
        \\
        \\pub fn local_code(): i32 {
        \\    return 42;
        \\}
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import .std.fs;
        \\
        \\fn main(): i32 {
        \\    return fs.local_code();
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);

    try helpers.expectNativeFileExitCode(std.testing.allocator, root_path, 42);
}

test "dependency package import resolves through manifest dependencies" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "app/src");
    try compat.dirMakePath(tmp.dir, "util/src");

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "app/cyna.toml", .data =
        \\name = "app"
        \\entry = "src/main.cy"
        \\
        \\[dependencies]
        \\util = "../util"
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "app/src/main.cy", .data =
        \\import util.math;
        \\
        \\fn main(): i32 {
        \\    return math.forty_two();
        \\}
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "util/cyna.toml", .data =
        \\name = "util"
        \\entry = "src/lib.cy"
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "util/src/math.cy", .data =
        \\
        \\pub fn forty_two(): i32 {
        \\    return 42;
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "app/src/main.cy");
    defer std.testing.allocator.free(root_path);

    try helpers.expectNativeFileExitCode(std.testing.allocator, root_path, 42);
}

test "dependency package import resolves through structured manifest dependency" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "app/src");
    try compat.dirMakePath(tmp.dir, "util/src");

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "app/cyna.toml", .data =
        \\name = "app"
        \\entry = "src/main.cy"
        \\
        \\[dependencies]
        \\util = { path = "../util", version = "0.2.0" }
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "app/src/main.cy", .data =
        \\import util.math;
        \\
        \\fn main(): i32 {
        \\    return math.forty_two();
        \\}
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "util/cyna.toml", .data =
        \\name = "util"
        \\version = "0.2.0"
        \\entry = "src/lib.cy"
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "util/src/math.cy", .data =
        \\
        \\pub fn forty_two(): i32 {
        \\    return 42;
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "app/src/main.cy");
    defer std.testing.allocator.free(root_path);

    try helpers.expectNativeFileExitCode(std.testing.allocator, root_path, 42);
}

test "manifest project root-package import resolves with leading dot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "app/src/lib");

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "app/cyna.toml", .data =
        \\name = "app"
        \\entry = "src/main.cy"
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "app/src/lib/math.cy", .data =
        \\
        \\pub fn forty_two(): i32 {
        \\    return 42;
        \\}
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "app/src/main.cy", .data =
        \\import .lib.math;
        \\
        \\fn main(): i32 {
        \\    return math.forty_two();
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "app/src/main.cy");
    defer std.testing.allocator.free(root_path);

    try helpers.expectNativeFileExitCode(std.testing.allocator, root_path, 42);
}

test "manifest project rejects bare self-package imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "app/src/lib");

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "app/cyna.toml", .data =
        \\name = "app"
        \\entry = "src/main.cy"
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "app/src/lib/math.cy", .data =
        \\
        \\pub fn forty_two(): i32 {
        \\    return 42;
        \\}
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "app/src/main.cy", .data =
        \\import lib.math;
        \\
        \\fn main(): i32 {
        \\    return math.forty_two();
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "app/src/main.cy");
    defer std.testing.allocator.free(root_path);

    try helpers.expectModuleParseFailed(std.testing.allocator, root_path);
}

test "manifest src key defines the root package source tree" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "app/pkg/lib");

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "app/cyna.toml", .data =
        \\name = "app"
        \\src = "pkg"
        \\entry = "pkg/bin/main.cy"
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "app/pkg/lib/math.cy", .data =
        \\
        \\pub fn forty_two(): i32 {
        \\    return 42;
        \\}
    });
    try compat.dirMakePath(tmp.dir, "app/pkg/bin");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "app/pkg/bin/main.cy", .data =
        \\import .lib.math;
        \\
        \\fn main(): i32 {
        \\    return math.forty_two();
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "app/pkg/bin/main.cy");
    defer std.testing.allocator.free(root_path);

    try helpers.expectNativeFileExitCode(std.testing.allocator, root_path, 42);
}

test "dependency package src key defines dependency source tree" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "app/src");
    try compat.dirMakePath(tmp.dir, "util/pkg");

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "app/cyna.toml", .data =
        \\name = "app"
        \\entry = "src/main.cy"
        \\
        \\[dependencies]
        \\util = "../util"
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "app/src/main.cy", .data =
        \\import util.math;
        \\
        \\fn main(): i32 {
        \\    return math.forty_two();
        \\}
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "util/cyna.toml", .data =
        \\name = "util"
        \\src = "pkg"
        \\entry = "pkg/lib.cy"
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "util/pkg/math.cy", .data =
        \\
        \\pub fn forty_two(): i32 {
        \\    return 42;
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "app/src/main.cy");
    defer std.testing.allocator.free(root_path);

    try helpers.expectNativeFileExitCode(std.testing.allocator, root_path, 42);
}

test "manifest project resolves std as a package import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "app/src");

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "app/cyna.toml", .data =
        \\name = "app"
        \\entry = "src/main.cy"
        \\
        \\[dependencies]
        \\std = "../std"
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "app/src/main.cy", .data =
        \\import std.alloc as rt_alloc;
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "app/src/main.cy");
    defer std.testing.allocator.free(root_path);

    var loaded = try loader.loadProgram(std.testing.allocator, root_path);
    defer loaded.deinit(std.testing.allocator);

    var saw_main = false;
    var saw_prelude = false;
    var saw_alloc = false;
    for (loaded.module_names) |module_name| {
        if (std.mem.eql(u8, module_name, "main")) saw_main = true;
        if (std.mem.eql(u8, module_name, "std.prelude")) saw_prelude = true;
        if (std.mem.eql(u8, module_name, "std.alloc")) saw_alloc = true;
    }

    try std.testing.expect(saw_main);
    try std.testing.expect(saw_prelude);
    try std.testing.expect(saw_alloc);
}

test "bare std import does not resolve local std directory in manifest project" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "app/src");
    try compat.dirMakePath(tmp.dir, "app/src/std");

    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "app/cyna.toml", .data =
        \\name = "app"
        \\entry = "src/main.cy"
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "app/src/std/fs.cy", .data =
        \\
        \\pub fn local_code(): i32 {
        \\    return 7;
        \\}
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "app/src/main.cy", .data =
        \\import std.fs;
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "app/src/main.cy");
    defer std.testing.allocator.free(root_path);

    var loaded = try loader.loadProgram(std.testing.allocator, root_path);
    defer loaded.deinit(std.testing.allocator);

    var saw_builtin_std_fs = false;
    var saw_local_std_fs = false;
    for (loaded.module_names) |module_name| {
        if (std.mem.eql(u8, module_name, "std.fs")) saw_builtin_std_fs = true;
    }
    for (loaded.sources) |source| {
        if (std.mem.indexOf(u8, source, "local_code") != null) saw_local_std_fs = true;
    }

    try std.testing.expect(saw_builtin_std_fs);
    try std.testing.expect(!saw_local_std_fs);
}

test "nested modules resolve imports from the package root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "hal/fu740");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "hal/fu740/uart.cy", .data =
        \\
        \\pub fn uart_code(): i32 {
        \\    return 42;
        \\}
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "hal/console.cy", .data =
        \\
        \\import hal.fu740.uart;
        \\
        \\pub fn console_code(): i32 {
        \\    return uart.uart_code();
        \\}
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import hal.console;
        \\
        \\fn main(): i32 {
        \\    return console.console_code();
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);

    try helpers.expectNativeFileExitCode(std.testing.allocator, root_path, 42);
}

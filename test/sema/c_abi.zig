const std = @import("std");
const compat = @import("cyna").compat;

const compiler = @import("cyna").compiler;
const loader = compiler.loader;
const sema = compiler.sema;
const helpers = @import("../helpers.zig");

test "C ABI rejects structural tuples" {
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "c_abi_tuple_parameter",
        \\extern c fn bad(value: (c_int, c_int)): c_int;
        \\fn main(): i32 { return 0; }
    , "is not allowed at a callable C boundary");
}

test "C ABI rejects error returns in imports and exports" {
    const declarations = [_][]const u8{
        "extern c fn load(): c_int!Status;",
        "export c fn load(): c_int!Status { return 42; }",
    };
    for (declarations) |declaration| {
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "c enum Status: i32 {{ failed = 1 }}\n{s}\nfn main(): i32 {{ return 0; }}",
            .{declaration},
        );
        defer std.testing.allocator.free(source);
        try helpers.expectSemanticFailedMessage(
            std.testing.allocator,
            "c_abi_reject_public_result",
            source,
            "type `result` is not allowed at a callable C boundary; use an explicit C-layout ABI type",
        );
    }
}

test "public extern functions can be imported across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/native.cy", .data =
        \\extern {
        \\    pub c("foreign_answer") fn foreign_answer(): c_int;
        \\    c("private_answer") fn private_answer(): c_int;
        \\}
        \\
        \\pub extern c("single_answer") fn single_answer(): c_int;
        \\
        \\pub export c("exported_answer") fn exported_answer(): c_int {
        \\    return 7;
        \\}
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import { exported_answer, foreign_answer, single_answer } from lib.native;
        \\
        \\fn main(): i32 {
        \\    const ignored = foreign_answer();
        \\    const ignored_single = single_answer();
        \\    const ignored_exported = exported_answer();
        \\    return 0;
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);
    var loaded = try loader.loadProgram(std.testing.allocator, root_path);
    defer loaded.deinit(std.testing.allocator);

    const module = try sema.buildSir(std.testing.allocator, root_path, loaded.program);
    defer module.deinit(std.testing.allocator);

    const imported = sema.findFunction(module, "foreign_answer").?;
    try std.testing.expect(imported.is_extern);
    try std.testing.expectEqualStrings("foreign_answer", imported.abi_name.?);
    const single = sema.findFunction(module, "single_answer").?;
    try std.testing.expect(single.is_extern);
    try std.testing.expectEqualStrings("single_answer", single.abi_name.?);
    const exported = sema.findFunction(module, "exported_answer").?;
    try std.testing.expect(exported.is_export);
    try std.testing.expectEqualStrings("exported_answer", exported.abi_name.?);
}

test "C ABI allows extern declaration paired with matching export definition" {
    const source =
        \\extern c("cycor_console_putc") fn platform_putc(ch: c_uchar): void;
        \\
        \\export c("cycor_console_putc") fn qemu_putc(ch: c_uchar): void {
        \\}
        \\
        \\fn main(): i32 {
        \\    platform_putc(65 as c_uchar);
        \\    return 42;
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "c_abi_extern_export_symbol_pair", source);
}

test "attribute C ABI allows extern declaration paired with matching export definition" {
    const source =
        \\@abi("c")
        \\@link.import("cycor_console_putc")
        \\fn platform_putc(ch: c_uchar): void;
        \\
        \\@abi("c")
        \\@link.export("cycor_console_putc")
        \\fn qemu_putc(ch: c_uchar): void {
        \\}
        \\
        \\fn main(): i32 {
        \\    platform_putc(65 as c_uchar);
        \\    return 42;
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "attribute_c_abi_extern_export_symbol_pair", source);
}

test "keyword and attribute C ABI spellings share one symbol contract" {
    const source =
        \\@abi("c")
        \\@link.import("cycor_console_putc")
        \\fn platform_putc(ch: c_uchar): void;
        \\
        \\export c("cycor_console_putc") fn qemu_putc(ch: c_uchar): void {
        \\}
        \\
        \\fn main(): i32 {
        \\    platform_putc(65 as c_uchar);
        \\    return 42;
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "mixed_spelling_c_abi_symbol_pair", source);
}

test "C ABI rejects extern export pair with incompatible signatures" {
    const source =
        \\extern c("cycor_console_putc") fn platform_putc(ch: c_uchar): void;
        \\
        \\export c("cycor_console_putc") fn qemu_putc(ch: c_int): void {
        \\}
        \\
        \\fn main(): i32 {
        \\    return 42;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "c_abi_extern_export_symbol_pair_mismatch",
        source,
        "incompatible extern/export declarations",
    );
}

test "raw-pointer extern globals lower semantically as symbol imports" {
    const source =
        \\extern {
        \\    c("marker") const marker: *i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    unchecked {
        \\        return *marker;
        \\    }
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "extern_raw_pointer_symbol_import", source);
}

test "mutable raw pointers safely widen to const raw parameters" {
    const source =
        \\fn observe(value: *const c_int): void {
        \\    unchecked {
        \\        const ignored = *value;
        \\    }
        \\}
        \\
        \\fn forward(value: *c_int): void {
        \\    observe(value);
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "raw_pointer_const_widen", source);
}

test "const raw pointers reject writes" {
    const source =
        \\fn overwrite(value: *const c_int): void {
        \\    unchecked {
        \\        *value = 1 as c_int;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "const_raw_pointer_write",
        source,
        "cannot assign through `*const` raw pointer",
    );
}

test "nested raw pointers retain per-level constness" {
    const source =
        \\extern c fn lookup(out: **const c_char): c_int;
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "nested_raw_pointer_const", source);
}

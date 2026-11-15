const std = @import("std");
const builtin = @import("builtin");

const helpers = @import("../../helpers.zig");

test "inline assembly requires unchecked" {
    const source =
        \\fn main(): i32 {
        \\    asm volatile {
        \\        "nop";
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectParseFailed(std.testing.allocator, "inline_asm_requires_unchecked", source);
}

test "inline assembly rejects undeclared placeholders" {
    const source =
        \\fn main(): i32 {
        \\    unchecked {
        \\        asm {
        \\            "mov {value}, {missing}";
        \\            in value = 42;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "inline_asm_missing_placeholder", source, "undeclared input");
}

test "inline assembly rejects unused inputs" {
    const source =
        \\fn main(): i32 {
        \\    unchecked {
        \\        asm {
        \\            "nop";
        \\            in value = 42;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "inline_asm_unused_input", source, "declared but never used");
}

test "inline assembly expression requires out placeholder" {
    const source =
        \\fn main(): i32 {
        \\    unchecked {
        \\        const value = asm(i32) {
        \\            "mov {left}, {right}";
        \\            in left = 40;
        \\            in right = 2;
        \\        };
        \\        return value;
        \\    }
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "inline_asm_expr_requires_out", source, "must use `{out}`");
}

test "inline assembly expression supports explicit output operand" {
    const source =
        \\fn main(): i32 {
        \\    unchecked {
        \\        const value = asm(i32) {
        \\            "mov {result}, {input}";
        \\            out reg result;
        \\            in reg input = 42;
        \\        };
        \\        return value;
        \\    }
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "inline_asm_explicit_output_operand", source);
}

test "bare bang infers try in assembly inputs" {
    const source =
        \\enum Failure { bad; }
        \\fn number(): i32!Failure { throw Failure.bad; }
        \\fn statement_input(): i32! {
        \\    unchecked { asm { "mov {input}, {input}"; in reg input = try number(); } }
        \\    return 0;
        \\}
        \\fn expression_input(): i32! {
        \\    unchecked {
        \\        return asm(i32) {
        \\            "mov {result}, {input}";
        \\            out reg result;
        \\            in reg input = try number();
        \\        };
        \\    }
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectSemanticSuccess(std.testing.allocator, "inferred_bang_asm_inputs", source);
}

test "inline assembly expression supports explicit inout operand" {
    const source =
        \\fn main(): i32 {
        \\    unchecked {
        \\        const value = asm(i32) {
        \\            "add {acc}, {rhs}";
        \\            inout reg acc = 40;
        \\            in reg rhs = 2;
        \\        };
        \\        return value;
        \\    }
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "inline_asm_explicit_inout_operand", source);
}

test "inline assembly expression supports tied input operand" {
    const source =
        \\fn main(): i32 {
        \\    unchecked {
        \\        const value = asm(i32) {
        \\            "add {result}, {seed}";
        \\            out reg result;
        \\            in tied reg seed = 40;
        \\        };
        \\        return value;
        \\    }
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "inline_asm_tied_input_operand", source);
}

test "inline assembly tied input requires explicit output" {
    const source =
        \\fn main(): i32 {
        \\    unchecked {
        \\        const value = asm(i32) {
        \\            "add {out}, {seed}";
        \\            in tied reg seed = 40;
        \\        };
        \\        return value;
        \\    }
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "inline_asm_tied_requires_out", source, "tied asm inputs require an explicit `out` operand");
}

test "inline assembly accepts supported register clobber" {
    if (builtin.target.cpu.arch != .aarch64) return;

    const source =
        \\fn main(): i32 {
        \\    unchecked {
        \\        asm {
        \\            "nop";
        \\            clobber x0;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "inline_asm_register_clobber_aarch64", source);
}

test "inline assembly rejects unsupported register clobber" {
    const source =
        \\fn main(): i32 {
        \\    unchecked {
        \\        asm {
        \\            "nop";
        \\            clobber weird;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    if (builtin.target.cpu.arch == .aarch64) {
        try helpers.expectSemanticFailedMessage(std.testing.allocator, "inline_asm_bad_register_clobber", source, "unsupported AArch64 asm clobber register");
    } else {
        try helpers.expectSemanticFailedMessage(std.testing.allocator, "inline_asm_bad_register_clobber", source, "register asm clobbers are unavailable for this target");
    }
}

const std = @import("std");
const sir = @import("../sema/sir.zig");
const capability = @import("../capability.zig");
const internal_error = @import("../internal_error.zig");

pub const Error = error{
    InvalidIdentity,
    InvalidSir,
    WriteFailed,
    MissingLocal,
    MissingResultContext,
    UnterminatedBlock,
} || sir.VerifyError || capability.Error || internal_error.Error || std.mem.Allocator.Error;

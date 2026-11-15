const std = @import("std");

// Executable reference algebra for N08, not the compiler's production origin
// analysis. Bits stand for concrete, parameter A, and projection of B.
const Origin = struct {
    bits: u3 = 0,
    unresolved: bool = false,

    fn join(a: Origin, b: Origin) Origin {
        if (a.unresolved or b.unresolved) return .{ .unresolved = true };
        return .{ .bits = a.bits | b.bits };
    }

    fn leq(a: Origin, b: Origin) bool {
        if (b.unresolved) return true;
        if (a.unresolved) return false;
        return (a.bits & b.bits) == a.bits;
    }
};

const Slot = union(enum) {
    unbound,
    bound: Origin,

    fn bind(slot: Slot, actual: Origin) Slot {
        return switch (slot) {
            .unbound => .{ .bound = actual },
            .bound => |previous| .{ .bound = previous.join(actual) },
        };
    }
};

fn fact(index: usize) Origin {
    return if (index == 8) .{ .unresolved = true } else .{ .bits = @intCast(index) };
}

test "N08 reference origin join is a finite semilattice" {
    for (0..9) |i| {
        const a = fact(i);
        try std.testing.expectEqual(a, a.join(a));
        for (0..9) |j| {
            const b = fact(j);
            try std.testing.expectEqual(a.join(b), b.join(a));
            try std.testing.expect(a.leq(a.join(b)));
            try std.testing.expect(b.leq(a.join(b)));
            for (0..9) |k| {
                const c = fact(k);
                try std.testing.expectEqual(a.join(b).join(c), a.join(b.join(c)));
                try std.testing.expect(a.join(c).leq(a.join(b).join(c)));
            }
        }
    }
}

test "N08 reference inference keeps unbound separate and is order independent" {
    const unknown = Origin{ .unresolved = true };
    const a = Origin{ .bits = 0b010 };
    const b = Origin{ .bits = 0b100 };
    const first = (Slot{ .unbound = {} }).bind(a).bind(b);
    const reverse = (Slot{ .unbound = {} }).bind(b).bind(a);
    try std.testing.expectEqual(first, reverse);
    try std.testing.expectEqual(a.join(b), first.bound);
    const uncertain = (Slot{ .unbound = {} }).bind(unknown).bind(a);
    try std.testing.expect(uncertain.bound.unresolved);
    try std.testing.expectEqual(uncertain, (Slot{ .unbound = {} }).bind(a).bind(unknown));
}

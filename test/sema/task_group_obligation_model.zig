const std = @import("std");

// One statically identified TaskGroup obligation. Each bit is a possible
// runtime state, not a count of groups. This is a reference model only.
const State = packed struct(u8) {
    absent: bool = false,
    source: bool = false,
    destination: bool = false,
    settled: bool = false,
    escaped: bool = false,
    _padding: u3 = 0,

    fn join(a: State, b: State) State {
        return @bitCast(@as(u8, @bitCast(a)) | @as(u8, @bitCast(b)));
    }

    fn leq(a: State, b: State) bool {
        const left: u8 = @bitCast(a);
        const right: u8 = @bitCast(b);
        return (left & right) == left;
    }

    fn move(a: State) error{InvalidSource}!State {
        if (a.source == false or a.destination or a.settled or a.escaped) return error.InvalidSource;
        var next = a;
        next.source = false;
        next.destination = true;
        return next;
    }

    fn settle(a: State) error{NotUniquelyLive}!State {
        if (!a.source or a.absent or a.destination or a.settled or a.escaped) return error.NotUniquelyLive;
        return .{ .settled = true };
    }

    fn exitSafe(a: State) bool {
        return !a.source and !a.destination;
    }
};

fn state(index: usize) State {
    return @bitCast(@as(u8, @intCast(index)));
}

test "N07 reference join is finite and preserves every possible state" {
    for (0..32) |i| {
        const a = state(i);
        try std.testing.expectEqual(a, a.join(a));
        for (0..32) |j| {
            const b = state(j);
            try std.testing.expectEqual(a.join(b), b.join(a));
            try std.testing.expect(a.leq(a.join(b)));
            try std.testing.expect(b.leq(a.join(b)));
            for (0..32) |k| {
                const c = state(k);
                try std.testing.expectEqual(a.join(b).join(c), a.join(b.join(c)));
            }
        }
    }
}

test "N07 reference transfer conserves the obligation and settlement consumes it once" {
    const created = State{ .source = true };
    const moved = try created.move();
    try std.testing.expect(!moved.source and moved.destination);
    try std.testing.expectError(error.InvalidSource, moved.move());
    try std.testing.expect(!created.exitSafe());
    try std.testing.expect(!moved.exitSafe());
    const settled = try created.settle();
    try std.testing.expect(settled.exitSafe());
    try std.testing.expectError(error.NotUniquelyLive, settled.settle());
}

test "N07 reference creation and terminal effects are edge-sensitive" {
    const success = State{ .source = true };
    const failure = State{ .absent = true };
    const joined = success.join(failure);
    try std.testing.expectError(error.NotUniquelyLive, joined.settle());
    try std.testing.expect(!joined.exitSafe());
    const settled_success = try success.settle();
    try std.testing.expect(settled_success.join(failure).exitSafe());
}

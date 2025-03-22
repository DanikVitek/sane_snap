const expectFmtSnapshot = @import("../root.zig").expectFmtSnapshot;

fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try expectFmtSnapshot(
        @src(),
        null,
        "{d}",
        .{add(4, 7)},
    );
}

test {
    _ = @import("dir/nested.zig");
}

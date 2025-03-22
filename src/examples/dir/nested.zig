const expectFmtSnapshot = @import("../../root.zig").expectFmtSnapshot;

test "nested test" {
    try expectFmtSnapshot(
        @src(),
        null,
        "",
        .{},
    );
}

test "testcases" {
    for (0..5) |i| {
        try expectFmtSnapshot(
            @src(),
            i,
            "{s}",
            .{"abcd"[0..i]},
        );
    }
}

const expectFmtSnapshot = @import("../root.zig").expectFmtSnapshot;
const expectStringSnapshot = @import("../root.zig").expectStringSnapshot;

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

test "multiline string" {
    try expectStringSnapshot(
        @src(),
        null,
        \\line 1
        \\line 2
        \\line 3
        ,
    );
}

test {
    _ = @import("dir/nested.zig");
}

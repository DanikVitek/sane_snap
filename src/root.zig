//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const std = @import("std");
const testing = std.testing;

const options = @import("options");

test {
    _ = @import("examples/examples.zig");
}

/// This function is intended to be used only in tests.
///
/// This function is used to test the formatted output based on the provided `fmt` and `args`.
/// If the output does not match the expected output, the test will fail.
/// The output is compared to the snapshot file in the `snapshots` directory.
///
/// ## Arguments:
/// * `src` is the source location of the call site. To get this, use `@src()`.
/// * `fmt` is the format string for the expected output.
/// * `args` is the arguments to the format string.
///
/// ## Example:
/// ```zig
/// const sane_snap = @import("sane_snap");
///
/// fn add(a: i32, b: i32) i32 {
///     return a + b;
/// }
///
/// test "basic add functionality" {
///     try sane_snap.expectFmtSnapshot(
///         @src(),
///         null,
///         "{d}",
///         .{add(3, 7)},
///     );
/// }
/// ```
pub fn expectFmtSnapshot(src: std.builtin.SourceLocation, testcase: ?usize, comptime fmt: []const u8, args: anytype) !void {
    const actual: []const u8 = try std.fmt.allocPrint(testing.allocator, fmt, args);
    defer testing.allocator.free(actual);
    try expectStringSnapshot(src, testcase, actual);
}

/// This function is intended to be used only in tests.
///
/// This function is used to test the formatted output based on the "{any}" formatting of the `actual` arg.
/// If the output does not match the expected output, the test will fail.
/// The output is compared to the snapshot file in the `snapshots` directory.
///
/// ## Arguments:
/// * `src` is the source location of the call site. To get this, use `@src()`.
/// * `actual` is the value to be formatted.
///
/// ## Example:
/// ```zig
/// const sane_snap = @import("sane_snap");
///
/// fn add(a: i32, b: i32) i32 {
///     return a + b;
/// }
///
/// test "basic add functionality" {
///     try sane_snap.expectAnySnapshot(
///         @src(),
///         null,
///         add(3, 7),
///     );
/// }
/// ```
pub fn expectAnySnapshot(src: std.builtin.SourceLocation, testcase: ?usize, actual: anytype) !void {
    try expectFmtSnapshot(src, testcase, "{any}", .{actual});
}

/// This function is intended to be used only in tests.
///
/// This function is used to test the provided `actual` string against the snapshot.
/// If the value does not match the expected one, the test will fail.
/// The output is compared to the snapshot file in the `snapshots` directory.
///
/// ## Arguments:
/// * `src` is the source location of the call site. To get this, use `@src()`.
/// * `actual` is the value to be checked.
///
/// ## Example:
/// ```zig
/// const sane_snap = @import("sane_snap");
///
/// fn add(a: i32, b: i32) i32 {
///     return a + b;
/// }
///
/// test "basic add functionality" {
///     var buf: [2]u8 = undefined;
///     try sane_snap.expectStringSnapshot(
///         @src(),
///         null,
///         try std.fmt.bufPrint(&buf, "{d}", .{add(3, 7)}),
///     );
/// }
/// ```
pub fn expectStringSnapshot(src: std.builtin.SourceLocation, testcase: ?usize, actual: []const u8) !void {
    try compareSnapshotOrCreateNew(src, testcase, actual);
}

fn compareSnapshotOrCreateNew(
    src: std.builtin.SourceLocation,
    testcase: ?usize,
    actual: []const u8,
) !void {
    const test_file_dir_path = std.fs.path.dirname(src.file) orelse "";

    const test_file_without_ext = b: {
        const test_file_with_ext = std.fs.path.basename(src.file);
        break :b test_file_with_ext[0 .. test_file_with_ext.len - 4]; // remove ".zig"
    };

    var int_buf: [21]u8 = [_]u8{'-'} ++ @as([20]u8, undefined);
    var int_len: usize = undefined;
    const testcase_str = if (testcase) |c| b: {
        int_len = std.fmt.formatIntBuf(int_buf[1..], c, 10, .lower, .{});
        break :b int_buf[0 .. 1 + int_len];
    } else null;

    const snapshot_file_name = try std.fmt.allocPrint(
        testing.allocator,
        "{s}-{s}{s}.snap",
        .{
            test_file_without_ext,
            src.fn_name[5..], // remove "test."
            if (testcase_str) |c| c else "",
        },
    );
    defer testing.allocator.free(snapshot_file_name);

    const snapshot_file_path = try std.fs.path.join(testing.allocator, &.{
        options.build_root_path,
        options.root_module,
        test_file_dir_path,
        "snapshots",
        snapshot_file_name,
    });
    defer testing.allocator.free(snapshot_file_path);

    const snapshot_file = std.fs.openFileAbsolute(
        snapshot_file_path,
        .{ .lock = .shared },
    ) catch |err| {
        if (err != error.FileNotFound) return err;

        try createNew(src, testcase_str, snapshot_file_path, actual);

        return error.NewSnapshot;
    };
    defer snapshot_file.close();

    const snapshot_file_reader = snapshot_file.reader();
    try snapshot_file_reader.skipUntilDelimiterOrEof('\n');
    try snapshot_file_reader.skipUntilDelimiterOrEof('\n');
    try snapshot_file_reader.skipUntilDelimiterOrEof('\n');

    var expected: std.ArrayList(u8) = .init(testing.allocator);
    defer expected.deinit();

    try streamUntilEof(snapshot_file_reader, expected.writer());

    testing.expectEqualStrings(expected.items, actual) catch |err| {
        try createNew(src, testcase_str, snapshot_file_path, actual);
        return err;
    };
}

fn createNew(
    src: std.builtin.SourceLocation,
    testcase: ?[]u8,
    snapshot_file_path: []const u8,
    actual: []const u8,
) !void {
    const new_snapshot_file_path = try testing.allocator.alloc(u8, snapshot_file_path.len + 4);
    defer testing.allocator.free(new_snapshot_file_path);
    @memcpy(new_snapshot_file_path[0..snapshot_file_path.len], snapshot_file_path);
    @memcpy(new_snapshot_file_path[snapshot_file_path.len..], ".new");

    const parent_dir = std.fs.path.dirname(new_snapshot_file_path).?;
    // std.debug.panic("{s}\n", .{parent_dir});

    std.fs.makeDirAbsolute(parent_dir) catch |err1| if (err1 != error.PathAlreadyExists) return err1;
    const new_snapshot_file = try std.fs.createFileAbsolute(
        new_snapshot_file_path,
        .{ .lock = .exclusive },
    );
    defer new_snapshot_file.close();

    const new_snapshot_file_writer = new_snapshot_file.writer();

    try new_snapshot_file_writer.print(
        \\{s}/{s}
        \\{d}:{d}{s}
        \\---
        \\{s}
    ,
        .{
            std.fs.path.basename(src.file),
            src.fn_name[5..], // remove "test."
            src.line,
            src.column,
            if (testcase) |c| b: {
                c[0] = '/';
                break :b c;
            } else "",
            actual,
        },
    );
}

fn streamUntilEof(
    reader: anytype,
    writer: anytype,
) (@TypeOf(reader).Error || @TypeOf(writer).Error)!void {
    while (true) {
        const byte: u8 = reader.readByte() catch |err| if (err == error.EndOfStream) break else return @errorCast(err);
        try writer.writeByte(byte);
    }
}

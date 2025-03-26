const std = @import("std");

const options = @import("options");

const DiffMatchPatch = @import("diffz");

const ansi_term = @import("ansi_term");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var new_snapshots = std.ArrayList([]const u8).init(alloc);
    defer new_snapshots.deinit();

    const sub_path: []const u8 = if (options.build_root) |b|
        b.path ++ std.fs.path.sep_str ++ b.module
    else b: {
        const clap = @import("clap");

        const path = "." ++ std.fs.path.sep_str;

        var args_iter = try std.process.argsWithAllocator(alloc);
        defer args_iter.deinit();

        const name = args_iter.next().?;

        const params = comptime clap.parseParamsComptime(
            \\-h, --help                 Print this help message and exit.
            \\    --root_module <string> Path to the root module of the project, relative to the cwd. Defaults to "src".
        );

        var diag: clap.Diagnostic = undefined;
        const res = clap.parseEx(clap.Help, &params, clap.parsers.default, &args_iter, .{
            .allocator = alloc,
            .diagnostic = &diag,
            .terminating_positional = 0,
        }) catch |err| {
            try diag.report(std.io.getStdErr().writer(), err);
            return err;
        };

        if (res.args.help != 0) {
            var buf_writer = std.io.bufferedWriter(std.io.getStdErr().writer());
            const writer = buf_writer.writer();

            try writer.print("Usage: {s} [options]\n\nOptions:\n", .{std.fs.path.basename(name)});
            try clap.help(writer, clap.Help, &params, .{});

            try buf_writer.flush();
            return;
        }

        const root_module = res.args.root_module orelse "src";

        break :b try std.fs.path.join(alloc, &.{ path, root_module });
    };
    defer if (options.build_root == null) alloc.free(sub_path);

    var project_root = try std.fs.cwd().openDir(sub_path, .{
        .iterate = true,
        .no_follow = true,
    });
    defer project_root.close();

    try traverseSnapshotDirs(alloc, project_root, sub_path, false);
}

fn traverseSnapshotDirs(
    child_alloc: std.mem.Allocator,
    parent_dir: std.fs.Dir,
    parent_dir_path: []const u8,
    is_snapshots_dir: bool,
) !void {
    var arena = std.heap.ArenaAllocator.init(child_alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    var dir_iter = parent_dir.iterateAssumeFirstIteration();
    while (dir_iter.next() catch |err| {
        std.debug.print(
            "Failed to iterate directory \"{s}\": {!}\n",
            .{ parent_dir_path, err },
        );
        return;
    }) |entry| : (_ = arena.reset(.retain_capacity)) {
        switch (entry.kind) {
            .directory => {
                if (is_snapshots_dir) continue;

                var dir = parent_dir.openDir(entry.name, .{
                    .iterate = true,
                    .no_follow = true,
                }) catch |err| {
                    std.debug.print(
                        "Failed to open directory \"{s}\": {!}\n",
                        .{ std.fs.path.fmtJoin(&.{ parent_dir_path, entry.name }), err },
                    );
                    continue;
                };
                defer dir.close();

                const dir_path = try std.fs.path.join(alloc, &.{ parent_dir_path, entry.name });

                try traverseSnapshotDirs(
                    alloc,
                    dir,
                    dir_path,
                    std.mem.eql(u8, std.fs.path.basename(entry.name), "snapshots"),
                );
            },
            .file => {
                if (!is_snapshots_dir) continue;
                if (!std.mem.endsWith(u8, entry.name, ".snap.new")) continue;

                const new_snap_file = parent_dir.openFile(
                    entry.name,
                    .{ .lock = .shared },
                ) catch |err| {
                    std.debug.print(
                        "Failed to open file \"{s}\": {!}\n",
                        .{ std.fs.path.fmtJoin(&.{ parent_dir_path, entry.name }), err },
                    );
                    continue;
                };
                var new_snap_file_closed = false;
                defer if (!new_snap_file_closed) new_snap_file.close();

                const snap_file_name = std.fs.path.stem(entry.name);
                var snap_file: ?std.fs.File = parent_dir.openFile(
                    snap_file_name,
                    .{ .lock = .shared },
                ) catch |err| switch (err) {
                    error.FileNotFound => null,
                    else => {
                        std.debug.print(
                            "Failed to open file \"{s}\": {!}\n",
                            .{ std.fs.path.fmtJoin(&.{ parent_dir_path, std.fs.path.stem(entry.name) }), err },
                        );
                        continue;
                    },
                };
                defer if (snap_file) |f| f.close();

                var snap_file_reader = if (snap_file) |f| std.io.bufferedReader(f.reader()) else null;
                const before: std.ArrayListUnmanaged(u8) = if (snap_file_reader) |*buf_r| b: {
                    const r = buf_r.reader();

                    try r.skipUntilDelimiterOrEof('\n');
                    try r.skipUntilDelimiterOrEof('\n');
                    try r.skipUntilDelimiterOrEof('\n');

                    var buf: std.ArrayListUnmanaged(u8) = .empty;
                    try streamUntilEof(r, buf.writer(alloc));

                    break :b buf;
                } else .empty;

                var new_snap_file_reader = std.io.bufferedReader(new_snap_file.reader());
                const header, const after = b: {
                    const r = new_snap_file_reader.reader();

                    var header: std.ArrayListUnmanaged(u8) = .empty;
                    try r.streamUntilDelimiter(header.writer(alloc), '\n', null);
                    try header.append(alloc, '\n');
                    try r.streamUntilDelimiter(header.writer(alloc), '\n', null);
                    try r.skipUntilDelimiterOrEof('\n');
                    try header.appendSlice(alloc, "\n---\n");

                    var body: std.ArrayListUnmanaged(u8) = .empty;
                    try streamUntilEof(r, body.writer(alloc));

                    break :b .{ header, body };
                };

                const dmp: DiffMatchPatch = .{ .diff_timeout = 0 };
                const diffs = try dmp.diff(alloc, before.items, after.items, false);

                const action = try promptAction(header.items, diffs.items);
                switch (action) {
                    .accept => {
                        if (snap_file) |f| {
                            f.close();
                            snap_file = null;
                        }
                        new_snap_file.close();
                        new_snap_file_closed = true;
                        try parent_dir.rename(entry.name, snap_file_name);
                    },
                    .reject => {
                        new_snap_file.close();
                        new_snap_file_closed = true;
                        try parent_dir.deleteFile(entry.name);
                    },
                    .skip => continue,
                    .exit => return,
                }
            },
            else => continue,
        }
    }
}

fn promptAction(header: []const u8, diffs: []const DiffMatchPatch.Diff) !Action {
    var buf_stdout = std.io.bufferedWriter(std.io.getStdOut().writer());
    const stdout = buf_stdout.writer();

    try ansi_term.terminal.beginSynchronizedUpdate(stdout);

    try stdout.writeByte('\n');

    try stdout.writeAll(header);

    var style: ?ansi_term.style.Style = null;
    for (diffs) |diff| switch (diff.operation) {
        .equal => try stdout.writeAll(diff.text),
        .insert => {
            const new_style: ansi_term.style.Style = .{
                .background = .{ .RGB = .{ .r = 0, .g = 0x80, .b = 0 } },
                .foreground = .{ .RGB = .{ .r = 0, .g = 0xFF, .b = 0 } },
            };
            try ansi_term.format.updateStyle(
                stdout,
                new_style,
                style,
            );
            style = new_style;
            try stdout.writeAll(diff.text);
        },
        .delete => {
            const new_style: ansi_term.style.Style = .{
                .background = .{ .RGB = .{ .r = 0x80, .g = 0, .b = 0 } },
                .foreground = .{ .RGB = .{ .r = 0xFF, .g = 0, .b = 0 } },
            };
            try ansi_term.format.updateStyle(
                stdout,
                new_style,
                style,
            );
            style = new_style;
            try stdout.writeAll(diff.text);
        },
    };

    try ansi_term.format.resetStyle(stdout);

    try stdout.writeAll("\n---\n\nAction:\n");

    inline for (comptime std.meta.tags(Action)) |action| {
        try stdout.writeAll("- ");
        const name = comptime @tagName(action);
        try ansi_term.format.updateStyle(stdout, comptime action.textStyle(), null);
        try stdout.writeByte(comptime std.ascii.toUpper(name[0]));
        try ansi_term.format.resetStyle(stdout);
        try stdout.writeAll(comptime name[1..] ++ "\n");
    }

    try ansi_term.terminal.endSynchronizedUpdate(stdout);

    try buf_stdout.flush();

    const stdin = std.io.getStdIn().reader();
    return inp: switch (try stdin.readByte()) {
        'a', 'A' => return .accept,
        'r', 'R' => return .reject,
        's', 'S' => return .skip,
        'e', 'E' => return .exit,
        else => continue :inp try stdin.readByte(),
    };
}

const Action = enum {
    accept,
    reject,
    skip,
    exit,

    inline fn textStyle(self: Action) ansi_term.style.Style {
        return switch (self) {
            .accept => .{
                .foreground = .{ .RGB = .{ .r = 0, .g = 0xFF, .b = 0 } },
                .font_style = .{ .underline = true },
            },
            .reject => .{
                .foreground = .{ .RGB = .{ .r = 0xFF, .g = 0, .b = 0 } },
                .font_style = .{ .underline = true },
            },
            .skip => .{
                .foreground = .{ .RGB = .{ .r = 0xFF, .g = 0xFF, .b = 0 } },
                .font_style = .{ .underline = true },
            },
            .exit => .{
                .font_style = .{ .underline = true },
            },
        };
    }
};

fn streamUntilEof(
    reader: anytype,
    writer: anytype,
) (@TypeOf(reader).Error || @TypeOf(writer).Error)!void {
    while (true) {
        const byte: u8 = reader.readByte() catch |err| if (err == error.EndOfStream) break else return @errorCast(err);
        try writer.writeByte(byte);
    }
}

test {
    std.testing.refAllDeclsRecursive(@This());
}

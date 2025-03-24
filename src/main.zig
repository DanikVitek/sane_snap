const std = @import("std");

const options = @import("options");

// const cli = @import("cli.zig");

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

    var project_root_iter = project_root.iterate();
    while (try project_root_iter.next()) |entry| {
        switch (entry.kind) {
            .directory => {},
            else => {},
        }
    }
}

// fn collectSnapshots(dir: std.fs.Dir, new_snapshots: *std.ArrayList([]const u8))

test {
    std.testing.refAllDeclsRecursive(@This());
}

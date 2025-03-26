# sane_snap

Zig library for snapshot testing.

Inspired by the [insta.rs](https://insta.rs) library for Rust.

Supported Zig version is `0.14.0`.

## Installation

First, add the library to your `build.zig.zon` file.
This can be done by adding the following console command:

```bash
zig fetch --save git+https://github.com/DanikVitek/sane_snap.git
```

Then, add the following to your `build.zig` file:

```zig
const sane_snap = b.dependency("sane_snap", .{
    // Optional argument. Default is "src".
    // Used to set the root directory of the module.
    .root_module = "<path relative to the project root>"
});

const exe_mod = b.createModule(...);
exe_mod.import("sane_snap", sane_snap.module("sane_snap"));
```

If you plan on using the CLI, one option is to connect is as a project tool,
which can be done by adding the following to your `build.zig` file:

```zig
const sane_snap_cli = sane_snap.module("sane_snap_cli");

const sane_snap_cli_tool = b.addExecutable(.{
    .name = "sane_snap",
    .root_module = sane_snap_cli,
});

const run_sane_snap_cli_tool_cmd = b.addRunArtifact(sane_snap_cli_tool);

const run_sane_snap_cli_tool_step = b.step(
    "snap",
    "Run the sane_snap cli as this project's tool",
);
run_sane_snap_cli_tool_step.dependOn(&run_sane_snap_cli_tool_cmd.step);
```

After that, all you need to to to run the CLI is to run the following command:

```bash
zig build snap
```

## Usage in tests

```zig
const sane_snap = @import("sane_snap");

fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try sane_snap.expectFmtSnapshot(
        @src(),
        null, // Set to a testcase number if you have multiple.
        "{d}",
        .{add(4, 7)},
    );
}

test "different cases" {
    const testcases = [_]struct{a: i32, b: i32}{
        .{ .a = 1, .b = 2 },
        .{ .a = 3, .b = 4 },
    };

    inline for (testcases, 0..) |case, i| {
        try sane_snap.expectFmtSnapshot(
            @src(),
            i,
            "{d}",
            .{add(case.a, case.b)},
        );
    }
}
```

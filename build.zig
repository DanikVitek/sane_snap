const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();

    var build_root_path_is_owned = false;
    const build_root_path = b.build_root.path orelse b: {
        const cwd = b.build_root.handle.realpathAlloc(b.allocator, ".") catch |err| std.debug.panic("{!}", .{err});
        build_root_path_is_owned = true;
        break :b cwd;
    };
    defer if (build_root_path_is_owned) b.allocator.free(build_root_path);

    options.addOption([]const u8, "build_root_path", build_root_path);

    const root_module = b.option(
        []const u8,
        "root_module",
        "The root module of the project. Defaults to \"src\"",
    ) orelse "src";
    options.addOption([]const u8, "root_module", root_module);

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    lib_mod.addOptions("options", options);

    const tool_mod, const exe_mod = createCliModules(
        b,
        "sane_snap_cli",
        target,
        optimize,
        build_root_path,
        root_module,
    );

    // // Modules can depend on one another using the `std.Build.Module.addImport` function.
    // // This is what allows Zig source code to use `@import("foo")` where 'foo' is not a
    // // file path. In this case, we set up `exe_mod` to import `lib_mod`.
    // exe_mod.addImport("sane_snap_lib", lib_mod);

    // Now, we will create a static library based on the module we created above.
    // This creates a `std.Build.Step.Compile`, which is the build step responsible
    // for actually invoking the compiler.
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "sane_snap",
        .root_module = lib_mod,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    const tool = b.addExecutable(.{
        .name = "sane_snap",
        .root_module = tool_mod,
    });

    const run_tool_cmd = b.addRunArtifact(tool);

    const run_tool_step = b.step("snap", "Run the sane_snap cli as this project's tool");
    run_tool_step.dependOn(&run_tool_cmd.step);

    // This creates another `std.Build.Step.Compile`, but this one builds an executable
    // rather than a static library.
    const exe = b.addExecutable(.{
        .name = "sane_snap",
        .root_module = exe_mod,
    });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_exe_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_exe_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_exe_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_exe_step = b.step("run", "Run the sane_snap cli as a standalone tool");
    run_exe_step.dependOn(&run_exe_cmd.step);

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const tool_unit_tests = b.addTest(.{
        .root_module = tool_mod,
    });

    const run_tool_unit_tests = b.addRunArtifact(tool_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_tool_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}

fn createCliModules(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_root_path: []const u8,
    root_module: []const u8,
) [2]*std.Build.Module {
    return .{
        createCliModule(b, .{ .tool = .{
            .name = name,
            .build_root_path = build_root_path,
            .root_module = root_module,
        } }),
        createCliModule(b, .{ .exe = .{
            .target = target,
            .optimize = optimize,
        } }),
    };
}

const CreateCliModuleOptions = union(enum) {
    tool: struct {
        name: []const u8,
        build_root_path: []const u8,
        root_module: []const u8,
    },
    exe: struct {
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    },
};

fn createCliModule(
    b: *std.Build,
    create_options: CreateCliModuleOptions,
) *std.Build.Module {
    const mod = switch (create_options) {
        .tool => |tool| b.addModule(tool.name, .{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
        }),
        .exe => |exe| b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = exe.target,
            .optimize = exe.optimize,
        }),
    };

    const options = b.addOptions();

    const options_writer = options.contents.writer();
    options_writer.writeAll(
        \\pub const BuildRoot = struct {
        \\    path: []const u8,
        \\    module: []const u8,
        \\};
        \\
        \\pub const build_root: ?BuildRoot = 
    ) catch @panic("OOM");

    switch (create_options) {
        .tool => |tool| {
            options_writer.writeAll(".{\n") catch @panic("OOM");
            options_writer.print("    .path = \"{}\",\n", .{std.zig.fmtEscapes(tool.build_root_path)}) catch @panic("OOM");
            options_writer.print("    .module = \"{}\",\n", .{std.zig.fmtEscapes(tool.root_module)}) catch @panic("OOM");
            options_writer.writeAll("};") catch @panic("OOM");
        },
        .exe => {
            options_writer.writeAll("null;") catch @panic("OOM");
        },
    }

    mod.addOptions("options", options);

    const diffz = b.dependency("diffz", .{});
    mod.addImport("diffz", diffz.module("diffz"));

    const ansi_term = b.dependency("ansi_term", .{});
    mod.addImport("ansi_term", ansi_term.module("ansi_term"));

    if (create_options == .exe) {
        const clap = b.dependency("clap", .{});
        mod.addImport("clap", clap.module("clap"));
    }
    return mod;
}

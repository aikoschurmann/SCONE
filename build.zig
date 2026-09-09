const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "scone",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();
    exe.linkSystemLibrary("z3");
    exe.linkSystemLibrary("sqlite3");

    // Optional user-provided Z3 path
    if (b.option([]const u8, "z3-path", "Path to Z3 installation directory (e.g. /opt/homebrew)")) |z3_path| {
        const include_path = b.fmt("{s}/include", .{z3_path});
        const lib_path = b.fmt("{s}/lib", .{z3_path});
        exe.addIncludePath(.{ .cwd_relative = include_path });
        exe.addLibraryPath(.{ .cwd_relative = lib_path });
    } else {
        // Defaults for macOS homebrew if no explicit path is given
        exe.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        exe.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }


    const fuzzer = b.addExecutable(.{
        .name = "fuzzer",
        .root_source_file = b.path("src/fuzzer.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzzer.linkLibC();
    fuzzer.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    fuzzer.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    fuzzer.addIncludePath(.{ .cwd_relative = "/opt/homebrew/Cellar/z3/4.15.4/include" });
    fuzzer.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/Cellar/z3/4.15.4/lib" });
    fuzzer.linkSystemLibrary("z3");
    b.installArtifact(fuzzer);


    const test_adaptive = b.addExecutable(.{
        .name = "test_adaptive",
        .root_source_file = b.path("src/test_adaptive.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_adaptive.linkLibC();
    test_adaptive.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    test_adaptive.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    test_adaptive.addIncludePath(.{ .cwd_relative = "/opt/homebrew/Cellar/z3/4.15.4/include" });
    test_adaptive.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/Cellar/z3/4.15.4/lib" });
    test_adaptive.linkSystemLibrary("z3");
    b.installArtifact(test_adaptive);


    const test_redundancy_fast = b.addExecutable(.{
        .name = "test_redundancy_fast",
        .root_source_file = b.path("src/test_redundancy_fast.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_redundancy_fast.linkLibC();
    test_redundancy_fast.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    test_redundancy_fast.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    test_redundancy_fast.addIncludePath(.{ .cwd_relative = "/opt/homebrew/Cellar/z3/4.15.4/include" });
    test_redundancy_fast.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/Cellar/z3/4.15.4/lib" });
    test_redundancy_fast.linkSystemLibrary("z3");
    b.installArtifact(test_redundancy_fast);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const compress_tool = b.addExecutable(.{
        .name = "compress_db",
        .root_source_file = b.path("src/compress_cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    compress_tool.linkLibC();
    compress_tool.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    compress_tool.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    compress_tool.addIncludePath(.{ .cwd_relative = "/opt/homebrew/Cellar/z3/4.15.4/include" });
    compress_tool.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/Cellar/z3/4.15.4/lib" });
    compress_tool.linkSystemLibrary("z3");
    compress_tool.linkSystemLibrary("sqlite3");
    b.installArtifact(compress_tool);
}

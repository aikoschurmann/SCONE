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

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

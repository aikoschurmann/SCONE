const std = @import("std");

pub fn build(b: *std.Build) void {
    // 1. Define the executable we want to build
    const exe = b.addExecutable(.{
        .name = "scone",
        .root_source_file = b.path("src/main.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });
    exe.linkLibC();
    exe.linkSystemLibrary("z3");
    exe.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    exe.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });

    // 2. Tell Zig to install the finished file into the zig-out/ folder
    b.installArtifact(exe);

    // 3. Create the run command
    const run_cmd = b.addRunArtifact(exe);

    // Ensure the app is actually built/installed before we try to run it
    run_cmd.step.dependOn(b.getInstallStep());

    // Allow passing arguments (e.g., `zig build run -- arg1 arg2`)
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // 4. Expose the "run" command to the Zig CLI
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "main",
        .target = target,
        .optimize = optimize,
    });
    exe.addCSourceFile(.{
        .file = b.path("main.cpp"),
    });

    const lib = b.addStaticLibrary(.{
        .name = "web",
        .root_source_file = b.path("web.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.linkLibrary(lib);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run = b.step("run", "Run app");
    run.dependOn(&run_cmd.step);
}

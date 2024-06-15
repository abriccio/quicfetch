const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "main",
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe.addCSourceFile(.{
        .file = b.path("example.cpp"),
    });

    const lib = b.addStaticLibrary(.{
        .name = "quicfetch",
        .root_source_file = b.path("quicfetch.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (target.result.os.tag == .windows) {
        lib.linkSystemLibrary2("Crypt32", .{});
        lib.linkSystemLibrary2("Ws2_32", .{});
    }

    exe.linkLibrary(lib);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run = b.step("run", "Run app");
    run.dependOn(&run_cmd.step);
}

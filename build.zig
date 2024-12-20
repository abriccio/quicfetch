const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_example = b.option(
        bool,
        "build-example",
        "Build example runner binary",
    ) orelse false;
    const build_options = b.addOptions();
    build_options.addOption(bool, "build-example", build_example);

    const lib = b.addStaticLibrary(.{
        .name = "quicfetch",
        .root_source_file = b.path("quicfetch.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
    });
    lib.bundle_compiler_rt = true;
    lib.root_module.addOptions("build-options", build_options);

    if (target.result.os.tag == .windows) {
        lib.linkSystemLibrary2("Crypt32", .{});
        lib.linkSystemLibrary2("Ws2_32", .{});
    }

    b.installArtifact(lib);

    if (build_example) {
        const cwd = b.build_root;
        const api_key = try cwd.handle.readFileAlloc(b.allocator, "._env", 256);
        const api_flag = try std.mem.concat(b.allocator, u8, &.{
            "-DAWS_API_KEY=",
            api_key,
        });
        const exe = b.addExecutable(.{
            .name = "main",
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        exe.addCSourceFile(.{
            .file = b.path("example.cpp"),
            .flags = &.{api_flag},
        });
        exe.addIncludePath(b.path("include"));
        exe.linkLibrary(lib);
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        const run = b.step("run", "Run app");
        run.dependOn(&run_cmd.step);
    }
}

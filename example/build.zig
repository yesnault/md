const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const md_dep = b.dependency("md", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "md-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        // Match md's own exe: the LLVM backend avoids a codegen segfault on 0.16.
        .use_llvm = true,
    });
    exe.root_module.addImport("md", md_dep.module("md"));
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Build and run the example");
    run_step.dependOn(&run.step);
}

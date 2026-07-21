// GENESIS_SEAL: 7c242080
//! Workspace root: builds the shared `lib` package and the `vakedz`
//! compiler executable. `zig build test` runs lib tests + vakedz tests.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("lib/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const vakedz_mod = b.createModule(.{
        .root_source_file = b.path("vakedz/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    vakedz_mod.addImport("lib", lib_mod);

    const vakedz = b.addExecutable(.{
        .name = "vakedz",
        .root_module = vakedz_mod,
    });
    b.installArtifact(vakedz);

    const run_cmd = b.addRunArtifact(vakedz);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run vakedz");
    run_step.dependOn(&run_cmd.step);

    const lib_tests = b.addTest(.{ .root_module = lib_mod });
    const vakedz_tests = b.addTest(.{ .root_module = vakedz_mod });

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
    test_step.dependOn(&b.addRunArtifact(vakedz_tests).step);

    const fmt_step = b.addFmt(.{
        .paths = &.{
            "build.zig",
            "build.zig.zon",
            "lib/build.zig.zon",
            "lib/src",
            "vakedz/src",
        },
        .check = true,
    });
    b.step("check", "zig fmt --check all sources").dependOn(&fmt_step.step);
}

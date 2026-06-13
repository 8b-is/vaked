//! vakedz build — the Zig front-end for the Vaked capability-graph language.
//!
//! Targets Zig 0.14 (std.Build API). Produces a single `vakedz` binary whose
//! subcommands mirror `vakedc`: parse | check | lower | all | cache.
//!
//!   zig build                 # build the binary into zig-out/bin/vakedz
//!   zig build run -- parse f  # build + run
//!   zig build test            # run the in-source unit tests

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "vakedz",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    // `zig build run -- <args>`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the vakedz CLI");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` — in-source unit tests across the modules.
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run vakedz unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

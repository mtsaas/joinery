const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Without debug information, for the container image.
    const strip = b.option(bool, "strip", "Leave out debug information") orelse false;

    const exe = b.addExecutable(.{
        .name = "joinery-relay",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = strip,
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the relay").dependOn(&run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.step("test", "Run the tests, the replay of the Swift relay's traces among them").dependOn(&b.addRunArtifact(tests).step);

    // Always optimized: a benchmark of a debug build measures the safety checks.
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    b.step("bench", "Time each step a frame takes").dependOn(&b.addRunArtifact(bench).step);

    // Load against a relay already running: `zig build load -- --rooms 100 --guests 3 --rate 20`.
    const load = b.addExecutable(.{
        .name = "load",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/load.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    const run_load = b.addRunArtifact(load);
    run_load.addPassthruArgs();
    b.step("load", "Load a running relay with rooms of hosts and guests, and report throughput and latency").dependOn(&run_load.step);
}

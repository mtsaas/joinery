const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "joinery-relay",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // The web client the relay serves to browsers opening a link: the app's, so the two never differ.
    const web_client: std.Build.Module.Import = .{ .name = "WebClient.html", .module = b.createModule(.{
        .root_source_file = b.path("../Joinery/Collaboration/Web/WebClient.html"),
    }) };
    exe.root_module.addImport(web_client.name, web_client.module);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the relay").dependOn(&run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{web_client},
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
        }),
    });
    b.step("bench", "Time each step a frame takes").dependOn(&b.addRunArtifact(bench).step);
}

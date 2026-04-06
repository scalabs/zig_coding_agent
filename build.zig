const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Router executable (CLI entrypoint in src/main.zig).
    const server = b.addExecutable(.{
        .name = "ollama-qwen-router",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(server);

    // Run the router: `zig build run`.
    const run_step = b.step("run", "Run the local Ollama Qwen API server");
    const run_cmd = b.addRunArtifact(server);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    // Fast compile check without running anything.
    const check_step = b.step("check", "Compile the server");
    check_step.dependOn(&server.step);

    // Main test entrypoint (pulls tests from imported modules).
    const root_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Keep direct type tests explicit as this file is also imported directly.
    const types_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/types.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_root_unit_tests = b.addRunArtifact(root_unit_tests);
    const run_types_unit_tests = b.addRunArtifact(types_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_root_unit_tests.step);
    test_step.dependOn(&run_types_unit_tests.step);
}

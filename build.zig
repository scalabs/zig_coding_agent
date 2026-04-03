const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const server = b.addExecutable(.{
        .name = "ollama-qwen-router",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const ollama_test = b.addExecutable(.{
        .name = "test-ollama-qwen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_ollama.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(server);
    b.installArtifact(ollama_test);

    const run_step = b.step("run", "Run the local Ollama Qwen API server");
    const run_cmd = b.addRunArtifact(server);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    const ollama_step = b.step("ollama-test", "Run the direct Ollama smoke test");
    const ollama_cmd = b.addRunArtifact(ollama_test);
    ollama_cmd.step.dependOn(b.getInstallStep());
    ollama_step.dependOn(&ollama_cmd.step);

    const check_step = b.step("check", "Compile the server and the Ollama smoke test");
    check_step.dependOn(&server.step);
    check_step.dependOn(&ollama_test.step);

    const main_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const types_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/types.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_main_unit_tests = b.addRunArtifact(main_unit_tests);
    const run_types_unit_tests = b.addRunArtifact(types_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_main_unit_tests.step);
    test_step.dependOn(&run_types_unit_tests.step);
}

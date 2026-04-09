const std = @import("std");

const TestTarget = enum {
    all,
    root,
    types,
    file,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const package_name = "zig_coding_agent";
    const exe_name = "zig-coding-agent";

    const test_target_raw = b.option([]const u8, "test-target", "Test target: all|root|types|file") orelse "all";
    const test_file = b.option([]const u8, "test-file", "Path to Zig file when -Dtest-target=file");
    const test_filter = b.option([]const u8, "test-filter", "Only run tests whose names contain this text");
    const test_target = std.meta.stringToEnum(TestTarget, test_target_raw) orelse {
        @panic("Invalid -Dtest-target value. Use all, root, types, or file.");
    };

    // Public package module (import as @import("zig_coding_agent")).
    const mod = b.addModule(package_name, .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // CLI executable entrypoint.
    const app = b.addExecutable(.{
        .name = exe_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = package_name, .module = mod },
            },
        }),
    });

    b.installArtifact(app);

    // Run command: `zig build run -- [args]`.
    const run_step = b.step("run", "Run the Zig Coding Agent server");
    const run_cmd = b.addRunArtifact(app);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    // Tests from the package root module.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // Tests from the executable root module.
    const exe_tests = b.addTest(.{
        .root_module = app.root_module,
    });

    // Focused tests for the frequently-edited shared types module.
    const types_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/types.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const run_types_unit_tests = b.addRunArtifact(types_unit_tests);

    if (test_filter) |filter| {
        run_mod_tests.addArg("--test-filter");
        run_mod_tests.addArg(filter);
        run_exe_tests.addArg("--test-filter");
        run_exe_tests.addArg(filter);
        run_types_unit_tests.addArg("--test-filter");
        run_types_unit_tests.addArg(filter);
    }

    var run_file_unit_tests: ?*std.Build.Step.Run = null;
    if (test_target == .file) {
        const file_path = test_file orelse @panic("-Dtest-target=file requires -Dtest-file=src/path.zig");
        const file_unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(file_path),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_file = b.addRunArtifact(file_unit_tests);
        if (test_filter) |filter| {
            run_file.addArg("--test-filter");
            run_file.addArg(filter);
        }
        run_file_unit_tests = run_file;
    }

    // Targetable test command.
    const test_step = b.step("test", "Run tests (use -Dtest-target=all|root|types|file)");
    switch (test_target) {
        .all => {
            test_step.dependOn(&run_mod_tests.step);
            test_step.dependOn(&run_exe_tests.step);
            test_step.dependOn(&run_types_unit_tests.step);
        },
        .root => {
            test_step.dependOn(&run_mod_tests.step);
            test_step.dependOn(&run_exe_tests.step);
        },
        .types => {
            test_step.dependOn(&run_types_unit_tests.step);
        },
        .file => {
            test_step.dependOn(&run_file_unit_tests.?.step);
        },
    }

    // Compile-only verification for app and built-in test modules.
    const check_step = b.step("check", "Compile app and built-in test modules without running");
    check_step.dependOn(&app.step);
    check_step.dependOn(&mod_tests.step);
    check_step.dependOn(&exe_tests.step);
    check_step.dependOn(&types_unit_tests.step);
}

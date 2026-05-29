const std = @import("std");

const TestTarget = enum {
    all,
    root,
    types,
    file,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size (default: ReleaseSafe)",
    ) orelse .ReleaseSafe;

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
        .optimize = optimize,
    });

    // CLI executable entrypoint.
    const app = b.addExecutable(.{
        .name = exe_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .imports = &.{
                .{ .name = package_name, .module = mod },
            },
        }),
    });
    // Linux native build avoids linkLibC (glibc/GCC 16 .sframe linker issues on Zig 0.15.2).
    // Windows needs libc for socket APIs (recvfrom, etc.).
    if (app.root_module.resolved_target.?.query.os_tag == .windows) {
        app.linkLibC();
    }

    b.installArtifact(app);

    // Cross-compile for Windows: `zig build windows`
    const windows_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
        .abi = .gnu,
    });
    const windows_app = b.addExecutable(.{
        .name = exe_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = windows_target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .imports = &.{
                .{ .name = package_name, .module = mod },
            },
        }),
    });
    windows_app.linkLibC();
    const windows_step = b.step("windows", "Cross-compile ReleaseSafe binary for x86_64-windows-gnu");
    windows_step.dependOn(&b.addInstallArtifact(windows_app, .{}).step);

    // Sibling eval runner: `zig build zig_evals` (requires ../zig_eval and a running harness).
    const zig_eval_root = b.option([]const u8, "eval-root", "Path to sibling zig_eval checkout") orelse "../zig_eval";
    const eval_registry = b.option([]const u8, "eval-registry", "Registry directory inside zig_eval") orelse "registry";
    const eval_service = b.option([]const u8, "eval-service", "Service name from registry/services.json") orelse "local-openai-compat";
    const harness_base = b.option([]const u8, "eval-harness-url", "Harness base URL for readiness checks") orelse "http://127.0.0.1:8081";
    const eval_wait_seconds = b.option(u32, "eval-wait-seconds", "Seconds to wait for harness readiness before failing") orelse 0;

    const preflight_script = b.fmt(
        \\if [ -f ".env" ]; then set -a; . ./.env; set +a; fi
        \\PROVIDER="${{LLM_ROUTER_PROVIDER:-ollama}}"
        \\for i in $(seq 0 {d}); do
        \\  if curl -sf "{s}/health" >/dev/null; then
        \\    PAYLOAD=$(printf '{{"messages":[{{"role":"user","content":"Reply OK"}}],"provider":"%s","model":"auto"}}' "$PROVIDER")
        \\    if curl -sf -X POST "{s}/v1/chat/completions" \
        \\      -H "Content-Type: application/json" \
        \\      ${{LLM_ROUTER_API_KEY:+-H "Authorization: Bearer $LLM_ROUTER_API_KEY"}} \
        \\      -d "$PAYLOAD" >/dev/null; then
        \\      exit 0
        \\    fi
        \\    echo "error: harness chat probe failed at {s}/v1/chat/completions (provider=$PROVIDER; is the LLM configured?)" >&2
        \\    exit 1
        \\  fi
        \\  if [ "$i" -eq {d} ]; then break; fi
        \\  sleep 1
        \\done
        \\echo "error: harness not reachable at {s}/health (start it with: zig build run -- --use-env)" >&2
        \\exit 1
    ,
        .{ eval_wait_seconds, harness_base, harness_base, harness_base, eval_wait_seconds, harness_base },
    );

    const eval_preflight = b.addSystemCommand(&.{ "sh", "-c", preflight_script });

    const build_zig_eval = b.addSystemCommand(&.{ "zig", "build", "-Doptimize=ReleaseSafe" });
    build_zig_eval.setCwd(b.path(zig_eval_root));
    build_zig_eval.step.dependOn(&eval_preflight.step);

    const run_evals_script = b.fmt(
        \\if [ -f ".env" ]; then set -a; . ./.env; set +a; fi
        \\cd "{s}" && zig build run -Doptimize=ReleaseSafe -- run --registry {s} --service {s} "$@"
    ,
        .{ zig_eval_root, eval_registry, eval_service },
    );

    const run_evals = b.addSystemCommand(&.{ "sh", "-c", run_evals_script, "zig_evals" });
    run_evals.step.dependOn(&build_zig_eval.step);
    if (b.args) |args| {
        run_evals.addArgs(args);
    }

    const zig_evals_step = b.step(
        "zig_evals",
        "Run zig_eval registry against a live harness (requires ../zig_eval; start server first)",
    );
    zig_evals_step.dependOn(&run_evals.step);

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

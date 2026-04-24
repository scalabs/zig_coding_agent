const std = @import("std");
const config = @import("../config.zig");
const types = @import("../types.zig");

pub const ShellFlavor = enum {
    cmd,
    bash,
};

pub fn execute(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    request: types.Request,
    flavor: ShellFlavor,
) !types.Response {
    const tool_name = switch (flavor) {
        .cmd => "cmd",
        .bash => "bash",
    };

    if (!app_config.tool_exec_enabled) {
        return try makeToolResponse(
            allocator,
            tool_name,
            try std.fmt.allocPrint(
                allocator,
                "DEBUG_TOOL_ERROR\ntool={s}\nmessage=command execution disabled\nset LLM_ROUTER_TOOL_EXEC_ENABLED=1 to enable",
                .{tool_name},
            ),
        );
    }

    const command = std.mem.trim(u8, request.prompt, " \t\r\n");
    if (command.len == 0) {
        return try makeToolResponse(
            allocator,
            tool_name,
            try std.fmt.allocPrint(
                allocator,
                "DEBUG_TOOL_ERROR\ntool={s}\nmessage=empty command prompt",
                .{tool_name},
            ),
        );
    }

    const argv = switch (flavor) {
        .cmd => [_][]const u8{ "cmd", "/C", command },
        .bash => [_][]const u8{ "bash", "-lc", command },
    };

    const run_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &argv,
        .max_output_bytes = app_config.tool_exec_max_output_bytes,
    }) catch |err| {
        return try makeToolResponse(
            allocator,
            tool_name,
            try std.fmt.allocPrint(
                allocator,
                "DEBUG_TOOL_ERROR\ntool={s}\nspawn_error={s}",
                .{ tool_name, @errorName(err) },
            ),
        );
    };
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);

    const term_text = try childTermToTextAlloc(allocator, run_result.term);
    defer allocator.free(term_text);

    const status_tag = if (isSuccessfulTermination(run_result.term)) "DEBUG_TOOL_OK" else "DEBUG_TOOL_ERROR";
    const output = try std.fmt.allocPrint(
        allocator,
        "{s}\ntool={s}\nterm={s}\nmax_output_bytes={d}\nconfigured_timeout_ms={d}\ncommand={s}\n--- stdout ---\n{s}\n--- stderr ---\n{s}",
        .{
            status_tag,
            tool_name,
            term_text,
            app_config.tool_exec_max_output_bytes,
            app_config.tool_exec_timeout_ms,
            command,
            run_result.stdout,
            run_result.stderr,
        },
    );

    return try makeToolResponse(allocator, tool_name, output);
}

fn makeToolResponse(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    output: []u8,
) !types.Response {
    errdefer allocator.free(output);

    const model_name = try std.fmt.allocPrint(allocator, "debug-tools/{s}", .{tool_name});
    errdefer allocator.free(model_name);

    return .{
        .id = null,
        .model = model_name,
        .output = output,
        .finish_reason = try allocator.dupe(u8, "tool"),
        .success = true,
        .usage = .{},
    };
}

fn isSuccessfulTermination(term: std.process.Child.Term) bool {
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn childTermToTextAlloc(
    allocator: std.mem.Allocator,
    term: std.process.Child.Term,
) ![]u8 {
    return switch (term) {
        .Exited => |code| try std.fmt.allocPrint(allocator, "exited:{d}", .{code}),
        .Signal => |sig| try std.fmt.allocPrint(allocator, "signal:{d}", .{sig}),
        .Stopped => |sig| try std.fmt.allocPrint(allocator, "stopped:{d}", .{sig}),
        .Unknown => |code| try std.fmt.allocPrint(allocator, "unknown:{d}", .{code}),
    };
}

pub fn buildTestConfig(allocator: std.mem.Allocator, enable_exec: bool) !config.Config {
    return .{
        .listen_host = try allocator.dupe(u8, "127.0.0.1"),
        .listen_port = 8081,
        .debug_logging = false,
        .default_provider = try allocator.dupe(u8, "ollama_qwen"),
        .request_timeout_ms = 30_000,
        .provider_timeout_ms = 60_000,
        .instance_id = try allocator.dupe(u8, "local-instance"),
        .auth_api_key = try allocator.dupe(u8, ""),
        .ollama_base_url = try allocator.dupe(u8, "http://127.0.0.1:11434"),
        .ollama_model = try allocator.dupe(u8, "qwen:7b"),
        .ollama_think = false,
        .ollama_num_predict = 128,
        .ollama_temperature = 0.7,
        .ollama_repeat_penalty = 1.05,
        .openai_base_url = try allocator.dupe(u8, "https://api.openai.com/v1"),
        .openai_api_key = try allocator.dupe(u8, ""),
        .openai_model = try allocator.dupe(u8, "gpt-4.1-mini"),
        .claude_base_url = try allocator.dupe(u8, "https://api.anthropic.com/v1"),
        .claude_api_key = try allocator.dupe(u8, ""),
        .claude_model = try allocator.dupe(u8, "claude-3-5-sonnet-latest"),
        .llama_cpp_base_url = try allocator.dupe(u8, "http://127.0.0.1:8080"),
        .llama_cpp_api_key = try allocator.dupe(u8, ""),
        .llama_cpp_model = try allocator.dupe(u8, "local-model"),
        .session_store_path = try allocator.dupe(u8, "logs/sessions"),
        .session_retention_messages = 24,
        .tool_exec_enabled = enable_exec,
        .tool_exec_timeout_ms = 15_000,
        .tool_exec_max_output_bytes = 65_536,
        .loop_stream_progress_enabled = true,
    };
}

test "execute cmd tool returns disabled marker when not enabled" {
    if (@import("builtin").os.tag != .windows) return;

    const allocator = std.testing.allocator;
    var cfg = try buildTestConfig(allocator, false);
    defer cfg.deinit(allocator);

    const messages = try allocator.alloc(types.Message, 1);
    messages[0] = .{
        .role = try allocator.dupe(u8, "user"),
        .content = try allocator.dupe(u8, "echo hello"),
    };

    const req = types.Request{
        .prompt = try allocator.dupe(u8, "echo hello"),
        .messages = messages,
        .provider = null,
        .model = null,
        .session_id = null,
        .tenant_id = null,
        .max_context_tokens = null,
        .tools = try allocator.alloc(types.Tool, 0),
        .tool_choice = null,
    };
    defer req.deinit(allocator);

    var result = try execute(allocator, &cfg, req, .cmd);
    defer result.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "DEBUG_TOOL_ERROR") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "disabled") != null);
}

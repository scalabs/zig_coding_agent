//! CLI entrypoint for running the router in server mode or prompt-loop mode.
const std = @import("std");
const root = @import("root.zig");

const LoopMode = enum {
    basic,
    agent,
};

/// Parsed CLI options with owned heap-allocated string fields.
const CliOptions = struct {
    prompt: ?[]u8 = null, // Enables prompt-loop mode when set.
    provider_override: ?[]u8 = null, // Optional provider alias from CLI.
    env_file_path: ?[]u8 = null, // Optional dotenv path loaded before config.
    use_env: bool = false, // Enable dotenv loading.
    loop_mode: LoopMode = .basic, // Iteration style for prompt loop mode.
    until_marker: []u8, // Loop exits when assistant output contains this marker.
    max_turns: usize = 8, // Safety cap to avoid unbounded loops.

    /// Releases all owned option buffers.
    ///
    /// Args:
    /// - self: mutable options struct containing owned allocations.
    /// - allocator: allocator that was used to allocate option buffers.
    pub fn deinit(self: *CliOptions, allocator: std.mem.Allocator) void {
        if (self.prompt) |prompt| allocator.free(prompt);
        if (self.provider_override) |provider| allocator.free(provider);
        if (self.env_file_path) |env_file_path| allocator.free(env_file_path);
        allocator.free(self.until_marker);
    }
};

/// Starts the process, loads config, and dispatches to server or prompt-loop mode.
///
/// Errors:
/// - allocator, configuration, CLI parsing, and provider/runtime errors.
pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var cli = try parseCliOptions(allocator);
    defer cli.deinit(allocator);

    var env_overrides: ?root.config.EnvOverrides = null;
    defer if (env_overrides) |*map| deinitEnvOverrides(map, allocator);

    if (cli.use_env or cli.env_file_path != null) {
        const env_path = cli.env_file_path orelse ".env";
        env_overrides = try loadDotEnvOverridesAlloc(allocator, env_path);
    }

    var app_config = if (env_overrides) |*overrides|
        try root.config.Config.loadWithOverrides(allocator, overrides)
    else
        try root.config.Config.load(allocator);
    defer app_config.deinit(allocator);

    if (cli.provider_override) |provider| {
        try app_config.setDefaultProvider(allocator, provider);
    }

    if (cli.prompt) |prompt| {
        try runPromptLoop(allocator, &app_config, prompt, cli.until_marker, cli.max_turns, cli.loop_mode);
        return;
    }

    try root.core.run(allocator, &app_config);
}

fn parseCliOptions(allocator: std.mem.Allocator) !CliOptions {
    var cli = CliOptions{
        .until_marker = try allocator.dupe(u8, "DONE"),
    };
    errdefer cli.deinit(allocator);

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();

    // Support both split flags (`--prompt value`) and inline flags (`--prompt=value`).
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--agent-loop")) {
            cli.loop_mode = .agent;
            continue;
        }

        if (std.mem.eql(u8, arg, "--loop-mode")) {
            const value = args.next() orelse return error.MissingLoopModeValue;
            cli.loop_mode = try parseLoopMode(value);
            continue;
        }

        if (std.mem.eql(u8, arg, "--use-env")) {
            cli.use_env = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--env-file")) {
            const value = args.next() orelse return error.MissingEnvFileValue;
            if (value.len == 0) return error.InvalidEnvFileValue;
            if (cli.env_file_path) |path| allocator.free(path);
            cli.env_file_path = try allocator.dupe(u8, value);
            cli.use_env = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--provider")) {
            const value = args.next() orelse return error.MissingProviderValue;
            if (cli.provider_override) |provider| allocator.free(provider);
            cli.provider_override = try allocator.dupe(u8, value);
            continue;
        }

        if (std.mem.eql(u8, arg, "--prompt")) {
            const value = args.next() orelse return error.MissingPromptValue;
            if (value.len == 0) return error.InvalidPromptValue;
            if (cli.prompt) |prompt| allocator.free(prompt);
            cli.prompt = try allocator.dupe(u8, value);
            continue;
        }

        if (std.mem.eql(u8, arg, "--until")) {
            const value = args.next() orelse return error.MissingUntilValue;
            if (value.len == 0) return error.InvalidUntilValue;
            allocator.free(cli.until_marker);
            cli.until_marker = try allocator.dupe(u8, value);
            continue;
        }

        if (std.mem.eql(u8, arg, "--max-turns")) {
            const value = args.next() orelse return error.MissingMaxTurnsValue;
            const parsed = try std.fmt.parseInt(usize, value, 10);
            if (parsed == 0) return error.InvalidMaxTurnsValue;
            cli.max_turns = parsed;
            continue;
        }

        const provider_prefix = "--provider=";
        if (std.mem.startsWith(u8, arg, provider_prefix)) {
            const value = arg[provider_prefix.len..];
            if (value.len == 0) return error.MissingProviderValue;
            if (cli.provider_override) |provider| allocator.free(provider);
            cli.provider_override = try allocator.dupe(u8, value);
            continue;
        }

        const prompt_prefix = "--prompt=";
        if (std.mem.startsWith(u8, arg, prompt_prefix)) {
            const value = arg[prompt_prefix.len..];
            if (value.len == 0) return error.InvalidPromptValue;
            if (cli.prompt) |prompt| allocator.free(prompt);
            cli.prompt = try allocator.dupe(u8, value);
            continue;
        }

        const until_prefix = "--until=";
        if (std.mem.startsWith(u8, arg, until_prefix)) {
            const value = arg[until_prefix.len..];
            if (value.len == 0) return error.InvalidUntilValue;
            allocator.free(cli.until_marker);
            cli.until_marker = try allocator.dupe(u8, value);
            continue;
        }

        const max_turns_prefix = "--max-turns=";
        if (std.mem.startsWith(u8, arg, max_turns_prefix)) {
            const value = arg[max_turns_prefix.len..];
            if (value.len == 0) return error.MissingMaxTurnsValue;
            const parsed = try std.fmt.parseInt(usize, value, 10);
            if (parsed == 0) return error.InvalidMaxTurnsValue;
            cli.max_turns = parsed;
            continue;
        }

        const env_file_prefix = "--env-file=";
        if (std.mem.startsWith(u8, arg, env_file_prefix)) {
            const value = arg[env_file_prefix.len..];
            if (value.len == 0) return error.InvalidEnvFileValue;
            if (cli.env_file_path) |path| allocator.free(path);
            cli.env_file_path = try allocator.dupe(u8, value);
            cli.use_env = true;
            continue;
        }

        const loop_mode_prefix = "--loop-mode=";
        if (std.mem.startsWith(u8, arg, loop_mode_prefix)) {
            const value = arg[loop_mode_prefix.len..];
            cli.loop_mode = try parseLoopMode(value);
            continue;
        }
    }

    return cli;
}

fn parseLoopMode(value: []const u8) !LoopMode {
    if (std.ascii.eqlIgnoreCase(value, "basic")) return .basic;
    if (std.ascii.eqlIgnoreCase(value, "agent")) return .agent;
    return error.InvalidLoopMode;
}

fn loadDotEnvOverridesAlloc(
    allocator: std.mem.Allocator,
    env_file_path: []const u8,
) !root.config.EnvOverrides {
    const content = std.fs.cwd().readFileAlloc(allocator, env_file_path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return error.EnvFileNotFound,
        else => return err,
    };
    defer allocator.free(content);

    var overrides = root.config.EnvOverrides.init(allocator);
    errdefer deinitEnvOverrides(&overrides, allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_index], " \t");
        if (key.len == 0) continue;

        const value_raw = std.mem.trim(u8, line[eq_index + 1 ..], " \t");
        const value = trimWrappingQuotes(value_raw);

        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);

        const owned_value = try allocator.dupe(u8, value);
        errdefer allocator.free(owned_value);

        if (overrides.fetchRemove(owned_key)) |entry| {
            allocator.free(entry.key);
            allocator.free(entry.value);
        }
        try overrides.put(owned_key, owned_value);
    }

    return overrides;
}

fn deinitEnvOverrides(
    overrides: *root.config.EnvOverrides,
    allocator: std.mem.Allocator,
) void {
    var iterator = overrides.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    overrides.deinit();
}

fn trimWrappingQuotes(value: []const u8) []const u8 {
    if (value.len < 2) return value;

    const first = value[0];
    const last = value[value.len - 1];
    if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
        return value[1 .. value.len - 1];
    }

    return value;
}

fn runPromptLoop(
    allocator: std.mem.Allocator,
    app_config: *const root.config.Config,
    initial_prompt: []const u8,
    until_marker: []const u8,
    max_turns: usize,
    loop_mode: LoopMode,
) !void {
    var conversation = std.ArrayList(root.types.Message){};
    defer {
        for (conversation.items) |message| {
            message.deinit(allocator);
        }
        conversation.deinit(allocator);
    }

    if (loop_mode == .agent) {
        try appendConversationMessage(
            allocator,
            &conversation,
            "system",
            "You are running in an iterative agent loop. Improve the solution every turn. Use concise self-critique before each improvement. When the task is complete, include the completion marker exactly.",
        );
    }

    try appendConversationMessage(allocator, &conversation, "user", initial_prompt);

    var latest_user_prompt = initial_prompt;
    var turn: usize = 0;
    var repeated_count: usize = 0;
    var previous_output: ?[]u8 = null;
    defer if (previous_output) |value| allocator.free(value);

    // Duplicate messages for each request so ownership remains local to this call.
    while (turn < max_turns) : (turn += 1) {
        var messages_copy = try allocator.alloc(root.types.Message, conversation.items.len);
        for (conversation.items, 0..) |msg, i| {
            messages_copy[i] = .{
                .role = try allocator.dupe(u8, msg.role),
                .content = try allocator.dupe(u8, msg.content),
            };
        }

        const request = root.types.Request{
            .prompt = try allocator.dupe(u8, latest_user_prompt),
            .messages = messages_copy,
            .provider = try allocator.dupe(u8, app_config.default_provider),
            .model = null,
            .session_id = null,
            .tenant_id = null,
            .max_context_tokens = null,
            .tools = try allocator.alloc(root.types.Tool, 0),
            .tool_choice = null,
        };
        defer request.deinit(allocator);

        var result = try root.backend.callProvider(allocator, app_config, request);
        defer result.deinit(allocator);

        std.debug.print("Turn {d}:\n{s}\n\n", .{ turn + 1, result.output });

        try appendConversationMessage(allocator, &conversation, "assistant", result.output);

        if (std.mem.indexOf(u8, result.output, until_marker) != null) {
            std.debug.print("Loop completed: found marker '{s}'.\n", .{until_marker});
            return;
        }

        const normalized_output = std.mem.trim(u8, result.output, " \t\r\n");
        if (previous_output) |prev| {
            if (std.mem.eql(u8, prev, normalized_output)) {
                repeated_count += 1;
            } else {
                repeated_count = 0;
            }
            allocator.free(prev);
        }
        previous_output = try allocator.dupe(u8, normalized_output);

        if (loop_mode == .agent and repeated_count >= 1) {
            std.debug.print("Loop stopped early: model repeated output without progress.\n", .{});
            return;
        }

        if (turn + 1 >= max_turns) {
            std.debug.print("Loop stopped after {d} turns without marker '{s}'.\n", .{ max_turns, until_marker });
            return;
        }

        latest_user_prompt = switch (loop_mode) {
            .basic => "Continue.",
            .agent => "Critique your previous answer briefly, then improve it with concrete next steps. If complete, include the completion marker exactly and return the final result.",
        };
        try appendConversationMessage(allocator, &conversation, "user", latest_user_prompt);
    }
}

fn appendConversationMessage(
    allocator: std.mem.Allocator,
    conversation: *std.ArrayList(root.types.Message),
    role: []const u8,
    content: []const u8,
) !void {
    try conversation.append(allocator, .{
        .role = try allocator.dupe(u8, role),
        .content = try allocator.dupe(u8, content),
    });
}

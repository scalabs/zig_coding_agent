//! CLI entrypoint for running the router in server mode or prompt-loop mode.
const std = @import("std");
const root = @import("root.zig");

/// Parsed CLI options with owned heap-allocated string fields.
const CliOptions = struct {
    prompt: ?[]u8 = null, // Enables prompt-loop mode when set.
    prompt_file: ?[]u8 = null, // Optional prompt file path.
    provider_override: ?[]u8 = null, // Optional provider alias from CLI.
    model_override: ?[]u8 = null, // Optional model override for prompt-loop requests.
    until_marker: []u8, // Loop exits when assistant output contains this marker.
    max_turns: usize = 8, // Safety cap to avoid unbounded loops.

    /// Releases all owned option buffers.
    ///
    /// Args:
    /// - self: mutable options struct containing owned allocations.
    /// - allocator: allocator that was used to allocate option buffers.
    pub fn deinit(self: *CliOptions, allocator: std.mem.Allocator) void {
        if (self.prompt) |prompt| allocator.free(prompt);
        if (self.prompt_file) |prompt_file| allocator.free(prompt_file);
        if (self.provider_override) |provider| allocator.free(provider);
        if (self.model_override) |model| allocator.free(model);
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

    if (cli.prompt != null and cli.prompt_file != null) {
        return error.ConflictingPromptSources;
    }

    if (cli.prompt == null) {
        if (cli.prompt_file) |prompt_file| {
            cli.prompt = try readPromptFileAlloc(allocator, prompt_file);
        }
    }

    var app_config = try root.config.Config.load(allocator);
    defer app_config.deinit(allocator);

    if (cli.provider_override) |provider| {
        try app_config.setDefaultProvider(allocator, provider);
    }

    if (cli.prompt) |prompt| {
        try runPromptLoop(
            allocator,
            &app_config,
            prompt,
            cli.until_marker,
            cli.max_turns,
            cli.model_override,
        );
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

        if (std.mem.eql(u8, arg, "--prompt-file")) {
            const value = args.next() orelse return error.MissingPromptFileValue;
            if (value.len == 0) return error.InvalidPromptFileValue;
            if (cli.prompt_file) |prompt_file| allocator.free(prompt_file);
            cli.prompt_file = try allocator.dupe(u8, value);
            continue;
        }

        if (std.mem.eql(u8, arg, "--model")) {
            const value = args.next() orelse return error.MissingModelValue;
            if (value.len == 0) return error.InvalidModelValue;
            if (cli.model_override) |model| allocator.free(model);
            cli.model_override = try allocator.dupe(u8, value);
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

        const prompt_file_prefix = "--prompt-file=";
        if (std.mem.startsWith(u8, arg, prompt_file_prefix)) {
            const value = arg[prompt_file_prefix.len..];
            if (value.len == 0) return error.InvalidPromptFileValue;
            if (cli.prompt_file) |prompt_file| allocator.free(prompt_file);
            cli.prompt_file = try allocator.dupe(u8, value);
            continue;
        }

        const model_prefix = "--model=";
        if (std.mem.startsWith(u8, arg, model_prefix)) {
            const value = arg[model_prefix.len..];
            if (value.len == 0) return error.InvalidModelValue;
            if (cli.model_override) |model| allocator.free(model);
            cli.model_override = try allocator.dupe(u8, value);
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
        }
    }

    return cli;
}

fn readPromptFileAlloc(
    allocator: std.mem.Allocator,
    prompt_file: []const u8,
) ![]u8 {
    const max_prompt_file_size = 256 * 1024;
    const content = try std.fs.cwd().readFileAlloc(
        allocator,
        prompt_file,
        max_prompt_file_size,
    );
    errdefer allocator.free(content);

    if (std.mem.trim(u8, content, " \t\r\n").len == 0) {
        return error.InvalidPromptFileValue;
    }

    return content;
}

fn runPromptLoop(
    allocator: std.mem.Allocator,
    app_config: *const root.config.Config,
    initial_prompt: []const u8,
    until_marker: []const u8,
    max_turns: usize,
    model_override: ?[]const u8,
) !void {
    var conversation = std.ArrayList(root.types.Message){};
    defer {
        for (conversation.items) |message| {
            message.deinit(allocator);
        }
        conversation.deinit(allocator);
    }

    try appendConversationMessage(allocator, &conversation, "user", initial_prompt);

    var latest_user_prompt = initial_prompt;
    var turn: usize = 0;

    // Duplicate messages for each request so ownership remains local to this call.
    while (turn < max_turns) : (turn += 1) {
        var attempt: usize = 0;

        var result: root.types.Response = undefined;
        while (true) {
            result = try callProviderForConversation(
                allocator,
                app_config,
                conversation.items,
                latest_user_prompt,
                model_override,
            );

            if (result.success) {
                break;
            }

            if (attempt == 0) {
                std.debug.print("Provider returned unsuccessful response, retrying once.\n", .{});
                attempt += 1;
                result.deinit(allocator);
                continue;
            }

            std.debug.print("Provider error after retry: {s}\n", .{result.output});
            result.deinit(allocator);
            return error.PromptLoopProviderFailed;
        }
        defer result.deinit(allocator);

        std.debug.print("Turn {d}:\n{s}\n\n", .{ turn + 1, result.output });

        try appendConversationMessage(allocator, &conversation, "assistant", result.output);

        if (std.mem.indexOf(u8, result.output, until_marker) != null) {
            std.debug.print("Loop completed: found marker '{s}'.\n", .{until_marker});
            return;
        }

        if (turn + 1 >= max_turns) {
            std.debug.print("Loop stopped after {d} turns without marker '{s}'.\n", .{ max_turns, until_marker });
            return;
        }

        latest_user_prompt = "Continue.";
        try appendConversationMessage(allocator, &conversation, "user", latest_user_prompt);
    }
}

fn callProviderForConversation(
    allocator: std.mem.Allocator,
    app_config: *const root.config.Config,
    conversation: []const root.types.Message,
    latest_user_prompt: []const u8,
    model_override: ?[]const u8,
) !root.types.Response {
    var messages_copy = try allocator.alloc(root.types.Message, conversation.len);
    var initialized_messages: usize = 0;
    errdefer {
        for (messages_copy[0..initialized_messages]) |message| {
            message.deinit(allocator);
        }
        allocator.free(messages_copy);
    }

    for (conversation, 0..) |message, i| {
        const role_copy = try allocator.dupe(u8, message.role);
        errdefer allocator.free(role_copy);
        const content_copy = try allocator.dupe(u8, message.content);

        messages_copy[i] = .{
            .role = role_copy,
            .content = content_copy,
        };
        initialized_messages += 1;
    }

    const request = root.types.Request{
        .prompt = try allocator.dupe(u8, latest_user_prompt),
        .messages = messages_copy,
        .provider = try allocator.dupe(u8, app_config.default_provider),
        .model = if (model_override) |value| try allocator.dupe(u8, value) else null,
    };
    defer request.deinit(allocator);

    return try root.backend.callProvider(allocator, app_config, request);
}

fn appendConversationMessage(
    allocator: std.mem.Allocator,
    conversation: *std.ArrayList(root.types.Message),
    role: []const u8,
    content: []const u8,
) !void {
    const role_copy = try allocator.dupe(u8, role);
    errdefer allocator.free(role_copy);

    const content_copy = try allocator.dupe(u8, content);
    errdefer allocator.free(content_copy);

    try conversation.append(allocator, .{
        .role = role_copy,
        .content = content_copy,
    });
}

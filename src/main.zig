const std = @import("std");
const root = @import("root.zig");

const CliOptions = struct {
    prompt: ?[]u8 = null,
    provider_override: ?[]u8 = null,
    until_marker: []u8,
    max_turns: usize = 8,

    pub fn deinit(self: *CliOptions, allocator: std.mem.Allocator) void {
        if (self.prompt) |prompt| allocator.free(prompt);
        if (self.provider_override) |provider| allocator.free(provider);
        allocator.free(self.until_marker);
    }
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var cli = try parseCliOptions(allocator);
    defer cli.deinit(allocator);

    var app_config = try root.config.Config.load(allocator);
    defer app_config.deinit(allocator);

    if (cli.provider_override) |provider| {
        try app_config.setDefaultProvider(allocator, provider);
    }

    if (cli.prompt) |prompt| {
        try runPromptLoop(allocator, &app_config, prompt, cli.until_marker, cli.max_turns);
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
        }
    }

    return cli;
}

fn runPromptLoop(
    allocator: std.mem.Allocator,
    app_config: *const root.config.Config,
    initial_prompt: []const u8,
    until_marker: []const u8,
    max_turns: usize,
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

        if (turn + 1 >= max_turns) {
            std.debug.print("Loop stopped after {d} turns without marker '{s}'.\n", .{ max_turns, until_marker });
            return;
        }

        latest_user_prompt = "Continue.";
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

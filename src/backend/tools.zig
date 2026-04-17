const std = @import("std");
const config = @import("../config.zig");
const types = @import("../types.zig");
const echo_tool = @import("../tools/echo.zig");
const utc_tool = @import("../tools/utc.zig");
const command_exec_tool = @import("../tools/command_exec.zig");

pub const ToolRegistry = struct {
    allowed_names: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) ToolRegistry {
        return .{ .allowed_names = std.StringHashMap(void).init(allocator) };
    }

    pub fn deinit(self: *ToolRegistry, allocator: std.mem.Allocator) void {
        var iterator = self.allowed_names.keyIterator();
        while (iterator.next()) |key| {
            allocator.free(key.*);
        }
        self.allowed_names.deinit();
    }

    pub fn register(self: *ToolRegistry, allocator: std.mem.Allocator, name: []const u8) !void {
        const key = try allocator.dupe(u8, name);
        errdefer allocator.free(key);
        try self.allowed_names.put(key, {});
    }

    pub fn isAllowed(self: *const ToolRegistry, name: []const u8) bool {
        return self.allowed_names.contains(name);
    }
};

pub fn validateRequestedTools(
    registry: *const ToolRegistry,
    tools: []const types.Tool,
) bool {
    for (tools) |tool| {
        if (!registry.isAllowed(tool.name)) return false;
    }
    return true;
}

/// Executes simple built-in debug tools directly in the harness.
///
/// This is intentionally minimal and deterministic so UI clients can verify
/// tool wiring without depending on upstream model behavior.
pub fn tryExecuteDebugTool(
    allocator: std.mem.Allocator,
    request: types.Request,
    app_config: *const config.Config,
) !?types.Response {
    const choice = request.tool_choice orelse return null;

    if (std.ascii.eqlIgnoreCase(choice, "echo")) {
        if (!hasRequestedTool(request.tools, "echo")) return null;
        return try echo_tool.execute(allocator, request);
    }

    if (std.ascii.eqlIgnoreCase(choice, "utc")) {
        if (!hasRequestedTool(request.tools, "utc")) return null;
        return try utc_tool.execute(allocator, request);
    }

    if (std.ascii.eqlIgnoreCase(choice, "cmd")) {
        if (!hasRequestedTool(request.tools, "cmd")) return null;
        return try command_exec_tool.execute(allocator, app_config, request, .cmd);
    }

    if (std.ascii.eqlIgnoreCase(choice, "bash")) {
        if (!hasRequestedTool(request.tools, "bash")) return null;
        return try command_exec_tool.execute(allocator, app_config, request, .bash);
    }

    return null;
}

pub fn maybeExecutePromptToolsAlloc(
    allocator: std.mem.Allocator,
    request: types.Request,
    app_config: *const config.Config,
) !?[]u8 {
    if (request.tools.len == 0) return null;

    if (request.tool_choice) |choice| {
        if (!std.ascii.eqlIgnoreCase(choice, "auto") and !std.ascii.eqlIgnoreCase(choice, "required")) {
            return null;
        }
    }

    const prompt = request.prompt;
    var output = std.ArrayList(u8){};
    defer output.deinit(allocator);

    var executed_any = false;
    try output.appendSlice(allocator, "Tool execution results:\n");

    if (hasRequestedTool(request.tools, "utc") and mentionsUtcIntent(prompt)) {
        const utc_result = try utc_tool.execute(allocator, request);
        defer utc_result.deinit(allocator);

        try output.writer(allocator).print("\n[tool=utc]\n{s}\n", .{utc_result.output});
        executed_any = true;
    }

    const command_to_run = try extractCommandFromPromptAlloc(allocator, prompt);
    defer if (command_to_run) |command| allocator.free(command);

    if (command_to_run) |command| {
        if (hasRequestedTool(request.tools, "cmd") and shouldUseCmd(prompt)) {
            const cmd_request = try buildSinglePromptRequestAlloc(allocator, command);
            defer cmd_request.deinit(allocator);

            const cmd_result = try command_exec_tool.execute(allocator, app_config, cmd_request, .cmd);
            defer cmd_result.deinit(allocator);

            try output.writer(allocator).print("\n[tool=cmd]\n{s}\n", .{cmd_result.output});
            executed_any = true;
        } else if (hasRequestedTool(request.tools, "bash") and shouldUseBash(prompt)) {
            const bash_request = try buildSinglePromptRequestAlloc(allocator, command);
            defer bash_request.deinit(allocator);

            const bash_result = try command_exec_tool.execute(allocator, app_config, bash_request, .bash);
            defer bash_result.deinit(allocator);

            try output.writer(allocator).print("\n[tool=bash]\n{s}\n", .{bash_result.output});
            executed_any = true;
        } else if (hasRequestedTool(request.tools, "cmd") and hasRequestedTool(request.tools, "bash")) {
            const cmd_request = try buildSinglePromptRequestAlloc(allocator, command);
            defer cmd_request.deinit(allocator);

            const cmd_result = try command_exec_tool.execute(allocator, app_config, cmd_request, .cmd);
            defer cmd_result.deinit(allocator);

            try output.writer(allocator).print("\n[tool=cmd]\n{s}\n", .{cmd_result.output});
            executed_any = true;
        }
    }

    if (!executed_any) return null;
    return try output.toOwnedSlice(allocator);
}

fn hasRequestedTool(tools: []const types.Tool, name: []const u8) bool {
    for (tools) |tool| {
        if (std.ascii.eqlIgnoreCase(tool.name, name)) return true;
    }
    return false;
}

fn mentionsUtcIntent(prompt: []const u8) bool {
    return containsIgnoreCase(prompt, "utc") or
        containsIgnoreCase(prompt, "time");
}

fn shouldUseCmd(prompt: []const u8) bool {
    return containsIgnoreCase(prompt, "cmd") or
        containsIgnoreCase(prompt, "windows") or
        containsIgnoreCase(prompt, "ping") or
        containsIgnoreCase(prompt, "command");
}

fn shouldUseBash(prompt: []const u8) bool {
    return containsIgnoreCase(prompt, "bash") or
        containsIgnoreCase(prompt, "shell") or
        containsIgnoreCase(prompt, "linux");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return indexOfIgnoreCase(haystack, needle) != null;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) {
            return i;
        }
    }
    return null;
}

fn extractCommandFromPromptAlloc(
    allocator: std.mem.Allocator,
    prompt: []const u8,
) !?[]u8 {
    const ping_idx = indexOfIgnoreCase(prompt, "ping ") orelse return null;
    const tail = prompt[ping_idx..];

    var end = tail.len;
    if (indexOfIgnoreCase(tail, " command")) |idx| {
        end = idx;
    }

    const command_slice = std.mem.trim(u8, tail[0..end], " \t\r\n\"'");
    if (command_slice.len == 0) return null;

    return try allocator.dupe(u8, command_slice);
}

fn buildSinglePromptRequestAlloc(
    allocator: std.mem.Allocator,
    prompt: []const u8,
) !types.Request {
    const messages = try allocator.alloc(types.Message, 1);
    errdefer allocator.free(messages);

    const role = try allocator.dupe(u8, "user");
    errdefer allocator.free(role);

    const content = try allocator.dupe(u8, prompt);
    errdefer allocator.free(content);

    messages[0] = .{
        .role = role,
        .content = content,
    };

    return .{
        .prompt = try allocator.dupe(u8, prompt),
        .messages = messages,
        .provider = null,
        .model = null,
        .session_id = null,
        .tenant_id = null,
        .max_context_tokens = null,
        .tools = try allocator.alloc(types.Tool, 0),
        .tool_choice = null,
    };
}

test "tryExecuteDebugTool executes echo when explicitly selected" {
    const allocator = std.testing.allocator;

    const messages = try allocator.alloc(types.Message, 1);
    messages[0] = .{
        .role = try allocator.dupe(u8, "user"),
        .content = try allocator.dupe(u8, "ping"),
    };

    const tools = try allocator.alloc(types.Tool, 1);
    tools[0] = .{
        .name = try allocator.dupe(u8, "echo"),
        .description = try allocator.dupe(u8, "debug echo"),
    };

    const req = types.Request{
        .prompt = try allocator.dupe(u8, "ping"),
        .messages = messages,
        .provider = null,
        .model = null,
        .session_id = null,
        .tenant_id = null,
        .max_context_tokens = null,
        .tools = tools,
        .tool_choice = try allocator.dupe(u8, "echo"),
    };
    defer req.deinit(allocator);

    var cfg = try command_exec_tool.buildTestConfig(allocator, false);
    defer cfg.deinit(allocator);

    const maybe_result = try tryExecuteDebugTool(allocator, req, &cfg);
    try std.testing.expect(maybe_result != null);

    var result = maybe_result.?;
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("debug-tools/echo", result.model);
    try std.testing.expectEqualStrings("tool", result.finish_reason);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DEBUG_TOOL_OK") != null);
}

test "tryExecuteDebugTool executes utc when explicitly selected" {
    const allocator = std.testing.allocator;

    const messages = try allocator.alloc(types.Message, 1);
    messages[0] = .{
        .role = try allocator.dupe(u8, "user"),
        .content = try allocator.dupe(u8, "time"),
    };

    const tools = try allocator.alloc(types.Tool, 1);
    tools[0] = .{
        .name = try allocator.dupe(u8, "utc"),
        .description = try allocator.dupe(u8, "current utc time"),
    };

    const req = types.Request{
        .prompt = try allocator.dupe(u8, "time"),
        .messages = messages,
        .provider = null,
        .model = null,
        .session_id = null,
        .tenant_id = null,
        .max_context_tokens = null,
        .tools = tools,
        .tool_choice = try allocator.dupe(u8, "utc"),
    };
    defer req.deinit(allocator);

    var cfg = try command_exec_tool.buildTestConfig(allocator, false);
    defer cfg.deinit(allocator);

    const maybe_result = try tryExecuteDebugTool(allocator, req, &cfg);
    try std.testing.expect(maybe_result != null);

    var result = maybe_result.?;
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("debug-tools/utc", result.model);
    try std.testing.expectEqualStrings("tool", result.finish_reason);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "tool=utc") != null);
}

test "maybeExecutePromptToolsAlloc runs utc from prompt intent" {
    const allocator = std.testing.allocator;

    const messages = try allocator.alloc(types.Message, 1);
    messages[0] = .{
        .role = try allocator.dupe(u8, "user"),
        .content = try allocator.dupe(u8, "get time with utc"),
    };

    const tools = try allocator.alloc(types.Tool, 1);
    tools[0] = .{
        .name = try allocator.dupe(u8, "utc"),
        .description = try allocator.dupe(u8, "utc tool"),
    };

    const req = types.Request{
        .prompt = try allocator.dupe(u8, "get time with utc"),
        .messages = messages,
        .provider = null,
        .model = null,
        .session_id = null,
        .tenant_id = null,
        .max_context_tokens = null,
        .tools = tools,
        .tool_choice = try allocator.dupe(u8, "auto"),
    };
    defer req.deinit(allocator);

    var cfg = try command_exec_tool.buildTestConfig(allocator, false);
    defer cfg.deinit(allocator);

    const summary = try maybeExecutePromptToolsAlloc(allocator, req, &cfg);
    defer if (summary) |value| allocator.free(value);

    try std.testing.expect(summary != null);
    try std.testing.expect(std.mem.indexOf(u8, summary.?, "[tool=utc]") != null);
}

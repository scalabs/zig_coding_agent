const std = @import("std");
const config = @import("../config.zig");
const types = @import("../types.zig");
const echo_tool = @import("../tools/echo.zig");
const utc_tool = @import("../tools/utc.zig");
const command_exec_tool = @import("../tools/command_exec.zig");
const file_ops_tool = @import("../tools/file_ops.zig");

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

pub fn noteToolCall(max_calls: usize, used_calls: *usize) !void {
    if (used_calls.* >= max_calls) return error.ToolCallLimitExceeded;
    used_calls.* += 1;
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
        const command = try command_exec_tool.extractCommandFromPromptAlloc(allocator, .cmd, request.prompt);
        defer if (command) |value| allocator.free(value);
        if (command == null) return null;
        return try command_exec_tool.execute(allocator, app_config, request, .cmd);
    }

    if (std.ascii.eqlIgnoreCase(choice, "bash")) {
        if (!hasRequestedTool(request.tools, "bash")) return null;
        const command = try command_exec_tool.extractCommandFromPromptAlloc(allocator, .bash, request.prompt);
        defer if (command) |value| allocator.free(value);
        if (command == null) return null;
        return try command_exec_tool.execute(allocator, app_config, request, .bash);
    }

    if (std.ascii.eqlIgnoreCase(choice, "file_read")) {
        if (!hasRequestedTool(request.tools, "file_read")) return null;
        return try file_ops_tool.execute(allocator, app_config, request, .read);
    }

    if (std.ascii.eqlIgnoreCase(choice, "file_write")) {
        if (!hasRequestedTool(request.tools, "file_write")) return null;
        return try file_ops_tool.execute(allocator, app_config, request, .write);
    }

    if (std.ascii.eqlIgnoreCase(choice, "file_search")) {
        if (!hasRequestedTool(request.tools, "file_search")) return null;
        return try file_ops_tool.execute(allocator, app_config, request, .search);
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
    var tool_calls: usize = 0;
    try output.appendSlice(allocator, "Tool execution results:\n");

    if (hasRequestedTool(request.tools, "utc") and mentionsUtcIntent(prompt)) {
        try noteToolCall(app_config.max_tool_calls_per_request, &tool_calls);
        const utc_result = try utc_tool.execute(allocator, request);
        defer utc_result.deinit(allocator);

        try output.writer(allocator).print("\n[tool=utc]\n{s}\n", .{utc_result.output});
        executed_any = true;
    }

    const cmd_requested = hasRequestedTool(request.tools, "cmd");
    const bash_requested = hasRequestedTool(request.tools, "bash");
    const file_write_requested = hasRequestedTool(request.tools, "file_write");
    const file_read_requested = hasRequestedTool(request.tools, "file_read");
    const file_search_requested = hasRequestedTool(request.tools, "file_search");

    if (file_read_requested and mentionsFileReadIntent(prompt)) {
        try noteToolCall(app_config.max_tool_calls_per_request, &tool_calls);
        const read_result = try file_ops_tool.execute(allocator, app_config, request, .read);
        defer read_result.deinit(allocator);
        try output.writer(allocator).print("\n[tool=file_read]\n{s}\n", .{read_result.output});
        executed_any = true;
    }

    if (file_search_requested and mentionsFileSearchIntent(prompt)) {
        try noteToolCall(app_config.max_tool_calls_per_request, &tool_calls);
        const search_result = try file_ops_tool.execute(allocator, app_config, request, .search);
        defer search_result.deinit(allocator);
        try output.writer(allocator).print("\n[tool=file_search]\n{s}\n", .{search_result.output});
        executed_any = true;
    }

    if (file_write_requested and mentionsPythonAddTwoNumbersIntent(prompt)) {
        const demo_path = "tmp/add_two_numbers.py";
        const demo_content =
            \\a = 2
            \\b = 3
            \\print(a + b)
            \\
        ;

        const write_prompt = try std.fmt.allocPrint(
            allocator,
            "write {s}\n```python\n{s}```",
            .{ demo_path, demo_content },
        );
        defer allocator.free(write_prompt);

        const write_req = try buildSinglePromptRequestAlloc(allocator, write_prompt);
        defer write_req.deinit(allocator);

        try noteToolCall(app_config.max_tool_calls_per_request, &tool_calls);
        const write_result = try file_ops_tool.execute(allocator, app_config, write_req, .write);
        defer write_result.deinit(allocator);

        try output.writer(allocator).print("\n[tool=file_write]\n{s}\n", .{write_result.output});
        executed_any = true;

        if (cmd_requested and @import("builtin").os.tag == .windows) {
            const run_prompt = try std.fmt.allocPrint(allocator, "python {s}", .{demo_path});
            defer allocator.free(run_prompt);
            const run_req = try buildSinglePromptRequestAlloc(allocator, run_prompt);
            defer run_req.deinit(allocator);

            try noteToolCall(app_config.max_tool_calls_per_request, &tool_calls);
            const run_result = try command_exec_tool.execute(allocator, app_config, run_req, .cmd);
            defer run_result.deinit(allocator);

            try output.writer(allocator).print("\n[tool=cmd]\n{s}\n", .{run_result.output});
        } else if (bash_requested and @import("builtin").os.tag != .windows) {
            const run_prompt = try std.fmt.allocPrint(allocator, "python3 {s}", .{demo_path});
            defer allocator.free(run_prompt);
            const run_req = try buildSinglePromptRequestAlloc(allocator, run_prompt);
            defer run_req.deinit(allocator);

            try noteToolCall(app_config.max_tool_calls_per_request, &tool_calls);
            const run_result = try command_exec_tool.execute(allocator, app_config, run_req, .bash);
            defer run_result.deinit(allocator);

            try output.writer(allocator).print("\n[tool=bash]\n{s}\n", .{run_result.output});
        }
    }

    if (cmd_requested) {
        const command_to_run = try command_exec_tool.extractCommandFromPromptAlloc(allocator, .cmd, prompt);
        defer if (command_to_run) |command| allocator.free(command);

        if (command_to_run) |command| {
            const cmd_request = try buildSinglePromptRequestAlloc(allocator, command);
            defer cmd_request.deinit(allocator);

            try noteToolCall(app_config.max_tool_calls_per_request, &tool_calls);
            const cmd_result = try command_exec_tool.execute(allocator, app_config, cmd_request, .cmd);
            defer cmd_result.deinit(allocator);

            try output.writer(allocator).print("\n[tool=cmd]\n{s}\n", .{cmd_result.output});
            executed_any = true;
        }
    }

    if (!executed_any and bash_requested) {
        const command_to_run = try command_exec_tool.extractCommandFromPromptAlloc(allocator, .bash, prompt);
        defer if (command_to_run) |command| allocator.free(command);

        if (command_to_run) |command| {
            const bash_request = try buildSinglePromptRequestAlloc(allocator, command);
            defer bash_request.deinit(allocator);

            try noteToolCall(app_config.max_tool_calls_per_request, &tool_calls);
            const bash_result = try command_exec_tool.execute(allocator, app_config, bash_request, .bash);
            defer bash_result.deinit(allocator);

            try output.writer(allocator).print("\n[tool=bash]\n{s}\n", .{bash_result.output});
            executed_any = true;
        }
    }

    if (!executed_any) return null;
    return try output.toOwnedSlice(allocator);
}

pub fn shouldShortCircuitAutoTools(request: types.Request) bool {
    if (request.tools.len == 0) return false;

    const choice = request.tool_choice orelse return false;
    if (!std.ascii.eqlIgnoreCase(choice, "auto") and !std.ascii.eqlIgnoreCase(choice, "required")) return false;

    const prompt = request.prompt;
    if (mentionsPythonAddTwoNumbersIntent(prompt)) return true;
    if (hasRequestedTool(request.tools, "file_read") and mentionsFileReadIntent(prompt)) return true;
    if (hasRequestedTool(request.tools, "file_search") and mentionsFileSearchIntent(prompt)) return true;
    return false;
}

pub fn makeAutoToolResponse(
    allocator: std.mem.Allocator,
    summary: []const u8,
) !types.Response {
    const model_name = try std.fmt.allocPrint(allocator, "debug-tools/{s}", .{"auto"});
    errdefer allocator.free(model_name);

    return .{
        .id = null,
        .model = model_name,
        .output = try allocator.dupe(u8, summary),
        .finish_reason = try allocator.dupe(u8, "tool"),
        .success = true,
        .usage = .{},
    };
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

fn mentionsFileReadIntent(prompt: []const u8) bool {
    return containsIgnoreCase(prompt, "file_read") or
        containsIgnoreCase(prompt, "read file") or
        containsIgnoreCase(prompt, "open file");
}

fn mentionsFileSearchIntent(prompt: []const u8) bool {
    return containsIgnoreCase(prompt, "file_search") or
        containsIgnoreCase(prompt, "search ") or
        containsIgnoreCase(prompt, "find ");
}

fn mentionsPythonAddTwoNumbersIntent(prompt: []const u8) bool {
    return containsIgnoreCase(prompt, "python") and
        containsIgnoreCase(prompt, "add two") and
        containsIgnoreCase(prompt, "execute");
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

test "maybeExecutePromptToolsAlloc extracts command for cmd" {
    if (@import("builtin").os.tag != .windows) return;

    const allocator = std.testing.allocator;

    const messages = try allocator.alloc(types.Message, 1);
    messages[0] = .{
        .role = try allocator.dupe(u8, "user"),
        .content = try allocator.dupe(u8, "Run the zig build test command"),
    };

    const tools = try allocator.alloc(types.Tool, 1);
    tools[0] = .{
        .name = try allocator.dupe(u8, "cmd"),
        .description = try allocator.dupe(u8, "windows command tool"),
    };

    const req = types.Request{
        .prompt = try allocator.dupe(u8, "Run the zig build test command"),
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

    var cfg = try command_exec_tool.buildTestConfig(allocator, true);
    defer cfg.deinit(allocator);

    const summary = try maybeExecutePromptToolsAlloc(allocator, req, &cfg);
    defer if (summary) |value| allocator.free(value);

    try std.testing.expect(summary != null);
    try std.testing.expect(std.mem.indexOf(u8, summary.?, "[tool=cmd]") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary.?, "command=zig build test") != null);
}

test "tryExecuteDebugTool ignores natural language cmd selection" {
    const allocator = std.testing.allocator;

    const messages = try allocator.alloc(types.Message, 1);
    messages[0] = .{
        .role = try allocator.dupe(u8, "user"),
        .content = try allocator.dupe(u8, "Please write a small C++ program"),
    };

    const tools = try allocator.alloc(types.Tool, 1);
    tools[0] = .{
        .name = try allocator.dupe(u8, "cmd"),
        .description = try allocator.dupe(u8, "windows command tool"),
    };

    const req = types.Request{
        .prompt = try allocator.dupe(u8, "Please write a small C++ program"),
        .messages = messages,
        .provider = null,
        .model = null,
        .session_id = null,
        .tenant_id = null,
        .max_context_tokens = null,
        .tools = tools,
        .tool_choice = try allocator.dupe(u8, "cmd"),
    };
    defer req.deinit(allocator);

    var cfg = try command_exec_tool.buildTestConfig(allocator, true);
    defer cfg.deinit(allocator);

    const maybe_result = try tryExecuteDebugTool(allocator, req, &cfg);
    try std.testing.expect(maybe_result == null);
}

test "noteToolCall enforces configured tool call cap" {
    var used: usize = 0;
    try noteToolCall(1, &used);
    try std.testing.expectEqual(@as(usize, 1), used);
    try std.testing.expectError(error.ToolCallLimitExceeded, noteToolCall(1, &used));
}

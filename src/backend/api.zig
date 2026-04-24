const std = @import("std");
const config = @import("../config.zig");
const types = @import("../types.zig");
pub const errors = @import("errors.zig");

/// Result of parsing a chat completion request.
///
/// Variants:
/// - ok: fully parsed and owned request ready for provider dispatch.
/// - err: API-shaped validation error suitable for client responses.
pub const ParseChatRequestResult = union(enum) {
    ok: types.Request,
    err: errors.ApiError,
};

/// Parses an OpenAI-style chat completion request from raw JSON bytes.
///
/// Args:
/// - allocator: allocator used for all owned strings and message copies.
/// - body: raw HTTP body bytes expected to contain a JSON object.
///
/// Returns:
/// - !ParseChatRequestResult: `.ok` with owned request or `.err` with validation details.
///
/// Errors:
/// - returns `error.OutOfMemory` on allocation failure.
/// - may return parse-library errors that are explicitly propagated.
pub fn parseChatRequest(
    allocator: std.mem.Allocator,
    body: []const u8,
) !ParseChatRequestResult {
    // Keep parse errors client-safe by mapping malformed JSON to validation errors.
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .err = errors.validationError(
            "Request body must be valid JSON",
            null,
            "invalid_json",
        ) },
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |object| object,
        else => return .{ .err = errors.validationError(
            "Request body must be a JSON object",
            null,
            "invalid_json",
        ) },
    };

    if (obj.get("messages") != null and obj.get("prompt") != null) {
        return .{ .err = errors.validationError(
            "Provide either messages or prompt, not both",
            null,
            "ambiguous_input",
        ) };
    }

    // Normalize aliases early so downstream code only sees canonical provider IDs.
    const provider = if (obj.get("provider")) |provider_value|
        switch (provider_value) {
            .string => |value| blk: {
                const trimmed = std.mem.trim(u8, value, " \t\r\n");
                if (trimmed.len == 0) {
                    return .{ .err = errors.validationError(
                        "provider must not be empty",
                        "provider",
                        "invalid_provider",
                    ) };
                }

                const normalized = types.normalizeProviderName(trimmed) orelse {
                    return .{ .err = errors.validationError(
                        "provider must be one of: ollama_qwen, ollama, qwen, openai, openrouter, claude, anthropic, bedrock, llama_cpp, llama.cpp",
                        "provider",
                        "invalid_provider",
                    ) };
                };

                break :blk try allocator.dupe(u8, normalized);
            },
            else => return .{ .err = errors.validationError(
                "provider must be a string",
                "provider",
                "invalid_provider",
            ) },
        }
    else
        null;
    errdefer if (provider) |value| allocator.free(value);

    // `model: "auto"` explicitly means "use provider default".
    const model_source = if (obj.get("model")) |model_value|
        switch (model_value) {
            .string => |value| blk: {
                const trimmed = std.mem.trim(u8, value, " \t\r\n");
                if (trimmed.len == 0) {
                    return .{ .err = errors.validationError(
                        "model must not be empty",
                        "model",
                        "invalid_model",
                    ) };
                }

                if (std.ascii.eqlIgnoreCase(trimmed, "auto")) {
                    break :blk null;
                }

                break :blk trimmed;
            },
            else => return .{ .err = errors.validationError(
                "model must be a string",
                "model",
                "invalid_model",
            ) },
        }
    else
        null;

    // Accept either `messages` (primary) or legacy single `prompt`.
    const parsed_messages = if (obj.get("messages")) |messages_value|
        switch (messages_value) {
            .array => |messages| blk: {
                if (messages.items.len == 0) {
                    return .{ .err = errors.validationError(
                        "messages must not be empty",
                        "messages",
                        "invalid_messages",
                    ) };
                }

                var collected = std.ArrayList(types.Message){};
                errdefer {
                    for (collected.items) |message| {
                        message.deinit(allocator);
                    }
                    collected.deinit(allocator);
                }

                for (messages.items) |message_value| {
                    const message_obj = switch (message_value) {
                        .object => |object| object,
                        else => return .{ .err = errors.validationError(
                            "Each message must be a JSON object",
                            "messages",
                            "invalid_messages",
                        ) },
                    };

                    const role = switch (message_obj.get("role") orelse {
                        return .{ .err = errors.validationError(
                            "Each message must include a role",
                            "messages",
                            "invalid_messages",
                        ) };
                    }) {
                        .string => |value| value,
                        else => return .{ .err = errors.validationError(
                            "message.role must be a string",
                            "messages",
                            "invalid_messages",
                        ) },
                    };

                    if (!isSupportedRole(role)) {
                        return .{ .err = errors.validationError(
                            "message.role must be one of: system, user, assistant, tool",
                            "messages",
                            "invalid_messages",
                        ) };
                    }

                    const content = switch (message_obj.get("content") orelse {
                        return .{ .err = errors.validationError(
                            "Each message must include content",
                            "messages",
                            "invalid_messages",
                        ) };
                    }) {
                        .string => |value| value,
                        else => return .{ .err = errors.validationError(
                            "message.content must be a string",
                            "messages",
                            "invalid_messages",
                        ) },
                    };

                    if (std.mem.trim(u8, content, " \t\r\n").len == 0) {
                        return .{ .err = errors.validationError(
                            "message.content must not be empty",
                            "messages",
                            "invalid_messages",
                        ) };
                    }

                    try collected.append(allocator, .{
                        .role = try allocator.dupe(u8, role),
                        .content = try allocator.dupe(u8, content),
                    });
                }

                if (!hasUserMessage(collected.items)) {
                    return .{ .err = errors.validationError(
                        "messages must include at least one user message",
                        "messages",
                        "invalid_messages",
                    ) };
                }

                break :blk try collected.toOwnedSlice(allocator);
            },
            else => return .{ .err = errors.validationError(
                "messages must be an array",
                "messages",
                "invalid_messages",
            ) },
        }
    else if (obj.get("prompt")) |prompt_value|
        switch (prompt_value) {
            .string => |value| blk: {
                if (value.len == 0) {
                    return .{ .err = errors.validationError(
                        "prompt must not be empty",
                        "prompt",
                        "invalid_prompt",
                    ) };
                }

                var messages = try allocator.alloc(types.Message, 1);
                errdefer allocator.free(messages);

                messages[0] = .{
                    .role = try allocator.dupe(u8, "user"),
                    .content = try allocator.dupe(u8, value),
                };

                break :blk messages;
            },
            else => return .{ .err = errors.validationError(
                "prompt must be a string",
                "prompt",
                "invalid_prompt",
            ) },
        }
    else
        return .{ .err = errors.validationError(
            "Request must include a messages array or prompt string",
            null,
            "missing_input",
        ) };
    errdefer {
        for (parsed_messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(parsed_messages);
    }

    const prompt = try extractLastUserPrompt(allocator, parsed_messages);
    errdefer allocator.free(prompt);

    const model = if (model_source) |value| try allocator.dupe(u8, value) else null;
    errdefer if (model) |value| allocator.free(value);

    const stream = if (obj.get("stream")) |stream_value|
        switch (stream_value) {
            .bool => |value| value,
            else => return .{ .err = errors.validationError(
                "stream must be a boolean",
                "stream",
                "invalid_stream",
            ) },
        }
    else
        false;

    const think = if (obj.get("think")) |think_value|
        switch (think_value) {
            .bool => |value| value,
            else => return .{ .err = errors.validationError(
                "think must be a boolean",
                "think",
                "invalid_think",
            ) },
        }
    else if (obj.get("thinking")) |thinking_value|
        switch (thinking_value) {
            .bool => |value| value,
            else => return .{ .err = errors.validationError(
                "thinking must be a boolean",
                "thinking",
                "invalid_thinking",
            ) },
        }
    else
        null;

    const temperature = if (obj.get("temperature")) |temperature_value|
        switch (temperature_value) {
            .float => |value| blk: {
                if (!std.math.isFinite(value)) {
                    return .{ .err = errors.validationError(
                        "temperature must be a finite number",
                        "temperature",
                        "invalid_temperature",
                    ) };
                }
                break :blk value;
            },
            .integer => |value| @as(f64, @floatFromInt(value)),
            else => return .{ .err = errors.validationError(
                "temperature must be a number",
                "temperature",
                "invalid_temperature",
            ) },
        }
    else
        null;

    const repeat_penalty = if (obj.get("repeat_penalty")) |repeat_penalty_value|
        switch (repeat_penalty_value) {
            .float => |value| blk: {
                if (!std.math.isFinite(value)) {
                    return .{ .err = errors.validationError(
                        "repeat_penalty must be a finite number",
                        "repeat_penalty",
                        "invalid_repeat_penalty",
                    ) };
                }
                break :blk value;
            },
            .integer => |value| @as(f64, @floatFromInt(value)),
            else => return .{ .err = errors.validationError(
                "repeat_penalty must be a number",
                "repeat_penalty",
                "invalid_repeat_penalty",
            ) },
        }
    else
        null;

    const session_id = if (obj.get("session_id")) |session_id_value|
        switch (session_id_value) {
            .string => |value| blk: {
                const trimmed = std.mem.trim(u8, value, " \t\r\n");
                if (trimmed.len == 0) {
                    return .{ .err = errors.validationError(
                        "session_id must not be empty",
                        "session_id",
                        "invalid_session_id",
                    ) };
                }
                break :blk try allocator.dupe(u8, trimmed);
            },
            else => return .{ .err = errors.validationError(
                "session_id must be a string",
                "session_id",
                "invalid_session_id",
            ) },
        }
    else
        null;
    errdefer if (session_id) |value| allocator.free(value);

    const tenant_id = if (obj.get("tenant_id")) |tenant_id_value|
        switch (tenant_id_value) {
            .string => |value| blk: {
                const trimmed = std.mem.trim(u8, value, " \t\r\n");
                if (trimmed.len == 0) {
                    return .{ .err = errors.validationError(
                        "tenant_id must not be empty",
                        "tenant_id",
                        "invalid_tenant_id",
                    ) };
                }
                break :blk try allocator.dupe(u8, trimmed);
            },
            else => return .{ .err = errors.validationError(
                "tenant_id must be a string",
                "tenant_id",
                "invalid_tenant_id",
            ) },
        }
    else
        null;
    errdefer if (tenant_id) |value| allocator.free(value);

    const max_context_tokens = if (obj.get("max_context_tokens")) |tokens_value|
        switch (tokens_value) {
            .integer => |value| blk: {
                if (value <= 0) {
                    return .{ .err = errors.validationError(
                        "max_context_tokens must be a positive integer",
                        "max_context_tokens",
                        "invalid_max_context_tokens",
                    ) };
                }

                if (value > 1_000_000) {
                    return .{ .err = errors.validationError(
                        "max_context_tokens must be <= 1000000",
                        "max_context_tokens",
                        "invalid_max_context_tokens",
                    ) };
                }
                break :blk @as(usize, @intCast(value));
            },
            else => return .{ .err = errors.validationError(
                "max_context_tokens must be a positive integer",
                "max_context_tokens",
                "invalid_max_context_tokens",
            ) },
        }
    else
        null;

    const parsed_tools = if (obj.get("tools")) |tools_value|
        switch (tools_value) {
            .array => |tool_array| blk: {
                var tools = std.ArrayList(types.Tool){};
                errdefer {
                    for (tools.items) |tool| {
                        tool.deinit(allocator);
                    }
                    tools.deinit(allocator);
                }

                for (tool_array.items) |tool_value| {
                    const tool_obj = switch (tool_value) {
                        .object => |value| value,
                        else => return .{ .err = errors.validationError(
                            "Each tool must be a JSON object",
                            "tools",
                            "invalid_tools",
                        ) },
                    };

                    const name = switch (tool_obj.get("name") orelse {
                        return .{ .err = errors.validationError(
                            "Each tool must include a name",
                            "tools",
                            "invalid_tools",
                        ) };
                    }) {
                        .string => |value| value,
                        else => return .{ .err = errors.validationError(
                            "tool.name must be a string",
                            "tools",
                            "invalid_tools",
                        ) },
                    };

                    const trimmed_name = std.mem.trim(u8, name, " \t\r\n");

                    if (trimmed_name.len == 0) {
                        return .{ .err = errors.validationError(
                            "tool.name must not be empty",
                            "tools",
                            "invalid_tools",
                        ) };
                    }

                    if (!isValidToolName(trimmed_name)) {
                        return .{ .err = errors.validationError(
                            "tool.name must be 1-64 chars using letters, numbers, _, -, or .",
                            "tools",
                            "invalid_tools",
                        ) };
                    }

                    for (tools.items) |existing_tool| {
                        if (std.mem.eql(u8, existing_tool.name, trimmed_name)) {
                            return .{ .err = errors.validationError(
                                "tool names must be unique",
                                "tools",
                                "invalid_tools",
                            ) };
                        }
                    }

                    const description = if (tool_obj.get("description")) |description_value|
                        switch (description_value) {
                            .string => |value| value,
                            else => return .{ .err = errors.validationError(
                                "tool.description must be a string",
                                "tools",
                                "invalid_tools",
                            ) },
                        }
                    else
                        "";

                    try tools.append(allocator, .{
                        .name = try allocator.dupe(u8, trimmed_name),
                        .description = try allocator.dupe(u8, description),
                    });
                }

                break :blk try tools.toOwnedSlice(allocator);
            },
            else => return .{ .err = errors.validationError(
                "tools must be an array",
                "tools",
                "invalid_tools",
            ) },
        }
    else
        try allocator.alloc(types.Tool, 0);
    errdefer {
        for (parsed_tools) |tool| {
            tool.deinit(allocator);
        }
        allocator.free(parsed_tools);
    }

    const tool_choice = if (obj.get("tool_choice")) |tool_choice_value|
        switch (tool_choice_value) {
            .string => |value| blk: {
                const trimmed = std.mem.trim(u8, value, " \t\r\n");
                if (trimmed.len == 0) {
                    return .{ .err = errors.validationError(
                        "tool_choice must not be empty",
                        "tool_choice",
                        "invalid_tool_choice",
                    ) };
                }
                break :blk try allocator.dupe(u8, trimmed);
            },
            else => return .{ .err = errors.validationError(
                "tool_choice must be a string",
                "tool_choice",
                "invalid_tool_choice",
            ) },
        }
    else
        null;
    errdefer if (tool_choice) |value| allocator.free(value);

    if (tool_choice) |choice| {
        if (!isBuiltinToolChoice(choice) and !hasToolNamed(parsed_tools, choice)) {
            deinitParsedRequestParts(
                allocator,
                provider,
                parsed_messages,
                prompt,
                model,
                session_id,
                tenant_id,
                parsed_tools,
                tool_choice,
            );
            return .{ .err = errors.validationError(
                "tool_choice must be one of: auto, none, required, or a requested tool name",
                "tool_choice",
                "invalid_tool_choice",
            ) };
        }

        if (parsed_tools.len == 0 and !std.ascii.eqlIgnoreCase(choice, "none") and !std.ascii.eqlIgnoreCase(choice, "auto")) {
            deinitParsedRequestParts(
                allocator,
                provider,
                parsed_messages,
                prompt,
                model,
                session_id,
                tenant_id,
                parsed_tools,
                tool_choice,
            );
            return .{ .err = errors.validationError(
                "tool_choice requires tools unless set to auto or none",
                "tool_choice",
                "invalid_tool_choice",
            ) };
        }
    }

    return .{ .ok = types.Request{
        .prompt = prompt,
        .messages = parsed_messages,
        .provider = provider,
        .model = model,
        .stream = stream,
        .think = think,
        .temperature = temperature,
        .repeat_penalty = repeat_penalty,
        .session_id = session_id,
        .tenant_id = tenant_id,
        .max_context_tokens = max_context_tokens,
        .tools = parsed_tools,
        .tool_choice = tool_choice,
    } };
}

/// Dispatches a parsed request to the configured provider implementation.
///
/// Args:
/// - allocator: allocator used by provider implementations.
/// - app_config: runtime config containing defaults and provider endpoints.
/// - request: normalized request that has already passed validation.
///
/// Returns:
/// - !types.Response: normalized completion response from provider.
///
/// Errors:
/// - returns `error.UnknownProvider` when provider alias cannot be resolved.
/// - propagates provider transport and parsing failures.
pub fn callProvider(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    request: types.Request,
) !types.Response {
    const requested_provider = request.provider orelse app_config.default_provider;
    const provider = types.normalizeProviderName(requested_provider) orelse {
        return error.UnknownProvider;
    };

    if (std.mem.eql(u8, provider, "ollama_qwen")) {
        const ollama_qwen = @import("../providers/ollama_qwen.zig");
        return try ollama_qwen.callQwen(allocator, app_config, request);
    }

    if (std.mem.eql(u8, provider, "openai")) {
        const openai = @import("../providers/openai.zig");
        return try openai.callOpenAI(allocator, app_config, request);
    }

    if (std.mem.eql(u8, provider, "openrouter")) {
        const openrouter = @import("../providers/openrouter.zig");
        return try openrouter.callOpenRouter(allocator, app_config, request);
    }

    if (std.mem.eql(u8, provider, "claude")) {
        const claude = @import("../providers/claude.zig");
        return try claude.callClaude(allocator, app_config, request);
    }

    if (std.mem.eql(u8, provider, "bedrock")) {
        const bedrock = @import("../providers/bedrock.zig");
        return try bedrock.callBedrock(allocator, app_config, request);
    }

    if (std.mem.eql(u8, provider, "llama_cpp")) {
        const llama_cpp = @import("../providers/llama_cpp.zig");
        return try llama_cpp.callLlamaCpp(allocator, app_config, request);
    }

    return error.UnknownProvider;
}

pub fn buildProviderStatusJson(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
) ![]u8 {
    const normalized_default = types.normalizeProviderName(app_config.default_provider) orelse app_config.default_provider;
    const escaped_default = try escapeJsonStringAlloc(allocator, normalized_default);
    defer allocator.free(escaped_default);

    const ollama_qwen = @import("../providers/ollama_qwen.zig");
    const ollama_status_json = try ollama_qwen.buildStatusJsonAlloc(allocator, app_config);
    defer allocator.free(ollama_status_json);

    const openrouter = @import("../providers/openrouter.zig");
    const openrouter_status_json = try openrouter.buildStatusJsonAlloc(allocator, app_config);
    defer allocator.free(openrouter_status_json);

    const bedrock = @import("../providers/bedrock.zig");
    const bedrock_status_json = try bedrock.buildStatusJsonAlloc(allocator, app_config);
    defer allocator.free(bedrock_status_json);

    return try std.fmt.allocPrint(
        allocator,
        "{{\"default_provider\":\"{s}\",\"ollama\":{s},\"openrouter\":{s},\"bedrock\":{s}}}",
        .{ escaped_default, ollama_status_json, openrouter_status_json, bedrock_status_json },
    );
}

fn hasUserMessage(messages: []const types.Message) bool {
    for (messages) |message| {
        if (std.ascii.eqlIgnoreCase(message.role, "user")) return true;
    }
    return false;
}

fn deinitParsedRequestParts(
    allocator: std.mem.Allocator,
    provider: ?[]const u8,
    parsed_messages: []const types.Message,
    prompt: []const u8,
    model: ?[]const u8,
    session_id: ?[]const u8,
    tenant_id: ?[]const u8,
    parsed_tools: []const types.Tool,
    tool_choice: ?[]const u8,
) void {
    if (provider) |value| allocator.free(value);

    for (parsed_messages) |message| {
        message.deinit(allocator);
    }
    allocator.free(parsed_messages);

    allocator.free(prompt);

    if (model) |value| allocator.free(value);
    if (session_id) |value| allocator.free(value);
    if (tenant_id) |value| allocator.free(value);

    for (parsed_tools) |tool| {
        tool.deinit(allocator);
    }
    allocator.free(parsed_tools);

    if (tool_choice) |value| allocator.free(value);
}

fn isSupportedRole(role: []const u8) bool {
    return std.ascii.eqlIgnoreCase(role, "system") or
        std.ascii.eqlIgnoreCase(role, "user") or
        std.ascii.eqlIgnoreCase(role, "assistant") or
        std.ascii.eqlIgnoreCase(role, "tool");
}

fn isValidToolName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |char| {
        const is_alpha_num = std.ascii.isAlphanumeric(char);
        if (!(is_alpha_num or char == '_' or char == '-' or char == '.')) {
            return false;
        }
    }
    return true;
}

fn isBuiltinToolChoice(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "auto") or
        std.ascii.eqlIgnoreCase(value, "none") or
        std.ascii.eqlIgnoreCase(value, "required");
}

fn hasToolNamed(tools: []const types.Tool, name: []const u8) bool {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return true;
    }
    return false;
}

fn extractLastUserPrompt(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
) ![]u8 {
    var i: usize = messages.len;
    while (i > 0) {
        i -= 1;
        const message = messages[i];
        if (std.ascii.eqlIgnoreCase(message.role, "user")) {
            return try allocator.dupe(u8, message.content);
        }
    }
    return error.NoUserMessage;
}

fn escapeJsonStringAlloc(
    allocator: std.mem.Allocator,
    input: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }

    return try out.toOwnedSlice(allocator);
}

test "parseChatRequest preserves messages and extracts last user prompt" {
    const allocator = std.testing.allocator;
    const body =
        \\{
        \\  "provider": "qwen",
        \\  "model": "qwen:7b",
        \\  "messages": [
        \\    {"role": "system", "content": "You are concise."},
        \\    {"role": "user", "content": "First question"},
        \\    {"role": "assistant", "content": "First answer"},
        \\    {"role": "user", "content": "Second question"}
        \\  ]
        \\}
    ;

    const parsed = try parseChatRequest(allocator, body);
    const request = switch (parsed) {
        .ok => |request| request,
        .err => return error.UnexpectedApiError,
    };
    defer request.deinit(allocator);

    try std.testing.expectEqualStrings("ollama_qwen", request.provider.?);
    try std.testing.expectEqualStrings("qwen:7b", request.model.?);
    try std.testing.expectEqualStrings("Second question", request.prompt);
    try std.testing.expectEqual(@as(usize, 4), request.messages.len);
    try std.testing.expectEqualStrings("system", request.messages[0].role);
    try std.testing.expectEqualStrings("Second question", request.messages[3].content);
}

test "parseChatRequest treats model auto as default" {
    const allocator = std.testing.allocator;
    const body =
        \\{
        \\  "provider": "ollama",
        \\  "model": "auto",
        \\  "messages": [
        \\    {"role": "user", "content": "Hello"}
        \\  ]
        \\}
    ;

    const parsed = try parseChatRequest(allocator, body);
    const request = switch (parsed) {
        .ok => |request| request,
        .err => return error.UnexpectedApiError,
    };
    defer request.deinit(allocator);

    try std.testing.expectEqualStrings("ollama_qwen", request.provider.?);
    try std.testing.expect(request.model == null);
    try std.testing.expectEqualStrings("Hello", request.prompt);
    try std.testing.expectEqual(@as(usize, 0), request.tools.len);
}

test "parseChatRequest accepts openrouter and bedrock providers" {
    const allocator = std.testing.allocator;

    const openrouter_body =
        \\{
        \\  "provider": "openrouter",
        \\  "messages": [
        \\    {"role": "user", "content": "Hello from OpenRouter"}
        \\  ]
        \\}
    ;

    const parsed_openrouter = try parseChatRequest(allocator, openrouter_body);
    const openrouter_request = switch (parsed_openrouter) {
        .ok => |request| request,
        .err => return error.UnexpectedApiError,
    };
    defer openrouter_request.deinit(allocator);

    try std.testing.expectEqualStrings("openrouter", openrouter_request.provider.?);
    try std.testing.expectEqualStrings("Hello from OpenRouter", openrouter_request.prompt);

    const bedrock_body =
        \\{
        \\  "provider": "bedrock",
        \\  "messages": [
        \\    {"role": "user", "content": "Hello from Bedrock"}
        \\  ]
        \\}
    ;

    const parsed_bedrock = try parseChatRequest(allocator, bedrock_body);
    const bedrock_request = switch (parsed_bedrock) {
        .ok => |request| request,
        .err => return error.UnexpectedApiError,
    };
    defer bedrock_request.deinit(allocator);

    try std.testing.expectEqualStrings("bedrock", bedrock_request.provider.?);
    try std.testing.expectEqualStrings("Hello from Bedrock", bedrock_request.prompt);
}

test "parseChatRequest rejects invalid provider" {
    const allocator = std.testing.allocator;
    const body =
        \\{
        \\  "provider": "bad-provider",
        \\  "messages": [
        \\    {"role": "user", "content": "Hello"}
        \\  ]
        \\}
    ;

    const parsed = try parseChatRequest(allocator, body);
    switch (parsed) {
        .ok => return error.ExpectedValidationError,
        .err => |api_error| {
            try std.testing.expectEqual(@as(u16, 400), api_error.status_code);
            try std.testing.expectEqualStrings("invalid_provider", api_error.code.?);
            try std.testing.expectEqualStrings("provider", api_error.param.?);
        },
    }
}

test "parseChatRequest rejects ambiguous prompt and messages" {
    const allocator = std.testing.allocator;
    const body =
        \\{
        \\  "prompt": "hello",
        \\  "messages": [
        \\    {"role": "user", "content": "hello"}
        \\  ]
        \\}
    ;

    const parsed = try parseChatRequest(allocator, body);
    switch (parsed) {
        .ok => return error.ExpectedValidationError,
        .err => |api_error| {
            try std.testing.expectEqual(@as(u16, 400), api_error.status_code);
            try std.testing.expectEqualStrings("ambiguous_input", api_error.code.?);
        },
    }
}

test "parseChatRequest rejects unsupported message role" {
    const allocator = std.testing.allocator;
    const body =
        \\{
        \\  "messages": [
        \\    {"role": "developer", "content": "hello"},
        \\    {"role": "user", "content": "continue"}
        \\  ]
        \\}
    ;

    const parsed = try parseChatRequest(allocator, body);
    switch (parsed) {
        .ok => return error.ExpectedValidationError,
        .err => |api_error| {
            try std.testing.expectEqual(@as(u16, 400), api_error.status_code);
            try std.testing.expectEqualStrings("invalid_messages", api_error.code.?);
            try std.testing.expectEqualStrings("messages", api_error.param.?);
        },
    }
}

test "parseChatRequest validates tool_choice against requested tools" {
    const allocator = std.testing.allocator;
    const body =
        \\{
        \\  "messages": [
        \\    {"role": "user", "content": "hello"}
        \\  ],
        \\  "tools": [
        \\    {"name": "echo", "description": "Echo input"}
        \\  ],
        \\  "tool_choice": "http_get"
        \\}
    ;

    const parsed = try parseChatRequest(allocator, body);
    switch (parsed) {
        .ok => return error.ExpectedValidationError,
        .err => |api_error| {
            try std.testing.expectEqual(@as(u16, 400), api_error.status_code);
            try std.testing.expectEqualStrings("invalid_tool_choice", api_error.code.?);
            try std.testing.expectEqualStrings("tool_choice", api_error.param.?);
        },
    }
}

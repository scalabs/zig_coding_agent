const std = @import("std");
const config = @import("../config.zig");
const types = @import("../types.zig");
pub const errors = @import("errors.zig");

/// Result of parsing a chat completion request
pub const ParseChatRequestResult = union(enum) {
    ok: types.Request,
    err: errors.ApiError,
};

/// Parse incoming chat completion request from JSON body
pub fn parseChatRequest(
    allocator: std.mem.Allocator,
    body: []const u8,
) !ParseChatRequestResult {
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

    const provider = if (obj.get("provider")) |provider_value|
        switch (provider_value) {
            .string => |value| blk: {
                const normalized = types.normalizeProviderName(value) orelse {
                    return .{ .err = errors.validationError(
                        "provider must be one of: ollama_qwen, ollama, qwen",
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

    const model_source = if (obj.get("model")) |model_value|
        switch (model_value) {
            .string => |value| blk: {
                if (value.len == 0) {
                    return .{ .err = errors.validationError(
                        "model must not be empty",
                        "model",
                        "invalid_model",
                    ) };
                }

                if (std.ascii.eqlIgnoreCase(value, "auto")) {
                    break :blk null;
                }

                break :blk value;
            },
            else => return .{ .err = errors.validationError(
                "model must be a string",
                "model",
                "invalid_model",
            ) },
        }
    else
        null;

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

                    if (content.len == 0) {
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

    return .{ .ok = types.Request{
        .prompt = prompt,
        .messages = parsed_messages,
        .provider = provider,
        .model = model,
    } };
}

/// Call the appropriate provider based on request configuration
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

    return error.UnknownProvider;
}

fn hasUserMessage(messages: []const types.Message) bool {
    for (messages) |message| {
        if (std.ascii.eqlIgnoreCase(message.role, "user")) return true;
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
}

test "parseChatRequest rejects invalid provider" {
    const allocator = std.testing.allocator;
    const body =
        \\{
        \\  "provider": "bedrock",
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

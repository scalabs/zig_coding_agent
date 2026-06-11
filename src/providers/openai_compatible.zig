const std = @import("std");
const types = @import("../types.zig");

pub fn callChat(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    api_key: ?[]const u8,
    model_name: []const u8,
    request: types.Request,
    provider_label: []const u8,
) !types.Response {
    return try callChatWithExtraHeaders(
        allocator,
        base_url,
        api_key,
        model_name,
        request,
        provider_label,
        &.{},
    );
}

pub fn callChatWithExtraHeaders(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    api_key: ?[]const u8,
    model_name: []const u8,
    request: types.Request,
    provider_label: []const u8,
    extra_headers: []const std.http.Header,
) !types.Response {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri_text = try buildUrl(allocator, base_url, "/chat/completions");
    defer allocator.free(uri_text);
    const uri = try std.Uri.parse(uri_text);

    const payload = try renderPayloadJsonAlloc(allocator, model_name, request);
    defer allocator.free(payload);

    var auth_header_buffer: ?[]u8 = null;
    defer if (auth_header_buffer) |h| allocator.free(h);

    var headers = std.ArrayList(std.http.Header){};
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = "content-type", .value = "application/json" });

    if (api_key) |key| {
        if (key.len > 0) {
            auth_header_buffer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
            try headers.append(allocator, .{ .name = "authorization", .value = auth_header_buffer.? });
        }
    }

    for (extra_headers) |header| {
        try headers.append(allocator, header);
    }

    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    const fetch_result = try client.fetch(.{
        .location = .{ .uri = uri },
        .method = .POST,
        .extra_headers = headers.items,
        .payload = payload,
        .response_writer = &writer.writer,
    });

    return try parseChatResponse(
        allocator,
        model_name,
        provider_label,
        fetch_result.status,
        writer.written(),
    );
}

fn buildUrl(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    suffix: []const u8,
) ![]u8 {
    if (std.mem.endsWith(u8, base_url, "/v1")) {
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url, suffix });
    }

    if (std.mem.endsWith(u8, base_url, "/v1/")) {
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url[0 .. base_url.len - 1], suffix });
    }

    if (std.mem.endsWith(u8, base_url, "/")) {
        return try std.fmt.allocPrint(allocator, "{s}v1{s}", .{ base_url, suffix });
    }

    return try std.fmt.allocPrint(allocator, "{s}/v1{s}", .{ base_url, suffix });
}

fn parseChatResponse(
    allocator: std.mem.Allocator,
    fallback_model: []const u8,
    provider_label: []const u8,
    status: std.http.Status,
    raw: []const u8,
) !types.Response {
    const is_http_ok = status == .ok;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
        if (is_http_ok) {
            return try makeFailureResponse(
                allocator,
                fallback_model,
                "Provider response was not valid JSON",
            );
        }

        const error_message = try std.fmt.allocPrint(
            allocator,
            "{s} returned HTTP {d}",
            .{ provider_label, @intFromEnum(status) },
        );
        defer allocator.free(error_message);

        return try makeFailureResponse(allocator, fallback_model, error_message);
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |value| value,
        else => return try makeFailureResponse(allocator, fallback_model, "Provider response was not a JSON object"),
    };

    if (extractErrorMessage(root)) |detail| {
        if (!is_http_ok) {
            const error_message = try std.fmt.allocPrint(
                allocator,
                "{s} returned HTTP {d}: {s}",
                .{ provider_label, @intFromEnum(status), detail },
            );
            defer allocator.free(error_message);

            return try makeFailureResponse(allocator, fallback_model, error_message);
        }

        return try makeFailureResponse(allocator, fallback_model, detail);
    }

    if (!is_http_ok) {
        const error_message = try std.fmt.allocPrint(
            allocator,
            "{s} returned HTTP {d}",
            .{ provider_label, @intFromEnum(status) },
        );
        defer allocator.free(error_message);

        return try makeFailureResponse(allocator, fallback_model, error_message);
    }

    const id_value = if (root.get("id")) |id_value|
        switch (id_value) {
            .string => |value| value,
            else => null,
        }
    else
        null;

    const model_value = if (root.get("model")) |model_value|
        switch (model_value) {
            .string => |value| value,
            else => fallback_model,
        }
    else
        fallback_model;

    const choices = switch (root.get("choices") orelse {
        return try makeFailureResponse(allocator, fallback_model, "Provider response missing choices");
    }) {
        .array => |value| value,
        else => return try makeFailureResponse(allocator, fallback_model, "Provider choices was not an array"),
    };

    if (choices.items.len == 0) {
        return try makeFailureResponse(allocator, fallback_model, "Provider choices array was empty");
    }

    const first_choice = switch (choices.items[0]) {
        .object => |value| value,
        else => return try makeFailureResponse(allocator, fallback_model, "Provider choice was not an object"),
    };

    const message_obj = switch (first_choice.get("message") orelse {
        return try makeFailureResponse(allocator, fallback_model, "Provider choice missing message");
    }) {
        .object => |value| value,
        else => return try makeFailureResponse(allocator, fallback_model, "Provider message was not an object"),
    };

    const tool_calls = try parseToolCallsAlloc(allocator, message_obj);
    errdefer if (tool_calls) |calls| {
        for (calls) |call| call.deinit(allocator);
        allocator.free(calls);
    };

    const output = if (message_obj.get("content")) |content_value|
        switch (content_value) {
            .string => |value| value,
            .null => "",
            else => return try makeFailureResponse(allocator, fallback_model, "Provider content was not a string"),
        }
    else if (tool_calls != null)
        ""
    else
        return try makeFailureResponse(allocator, fallback_model, "Provider message missing content");

    const finish_reason = if (first_choice.get("finish_reason")) |finish_reason_value|
        switch (finish_reason_value) {
            .string => |value| value,
            else => "stop",
        }
    else
        "stop";

    const usage = if (root.get("usage")) |usage_value|
        switch (usage_value) {
            .object => |usage_obj| types.Usage{
                .prompt_tokens = parseUsageField(usage_obj.get("prompt_tokens")),
                .completion_tokens = parseUsageField(usage_obj.get("completion_tokens")),
                .total_tokens = parseUsageField(usage_obj.get("total_tokens")),
            },
            else => types.Usage{},
        }
    else
        types.Usage{};

    return .{
        .id = if (id_value) |value| try allocator.dupe(u8, value) else null,
        .model = try allocator.dupe(u8, model_value),
        .output = try allocator.dupe(u8, output),
        .finish_reason = try allocator.dupe(u8, finish_reason),
        .success = true,
        .usage = usage,
        .tool_calls = tool_calls,
    };
}

fn parseToolCallsAlloc(
    allocator: std.mem.Allocator,
    message_obj: std.json.ObjectMap,
) !?[]types.ToolCall {
    const tool_calls_value = message_obj.get("tool_calls") orelse return null;
    const tool_calls_array = switch (tool_calls_value) {
        .array => |value| value,
        else => return null,
    };
    if (tool_calls_array.items.len == 0) return null;

    var calls = std.ArrayList(types.ToolCall){};
    errdefer {
        for (calls.items) |call| call.deinit(allocator);
        calls.deinit(allocator);
    }

    for (tool_calls_array.items, 0..) |call_value, index| {
        const call_obj = switch (call_value) {
            .object => |value| value,
            else => continue,
        };
        const function_obj = switch (call_obj.get("function") orelse continue) {
            .object => |value| value,
            else => continue,
        };
        const name = switch (function_obj.get("name") orelse continue) {
            .string => |value| value,
            else => continue,
        };
        const arguments_json = try parseToolArgumentsJsonAlloc(allocator, function_obj);
        errdefer allocator.free(arguments_json);

        const id = if (call_obj.get("id")) |id_value|
            switch (id_value) {
                .string => |value| try allocator.dupe(u8, value),
                else => try std.fmt.allocPrint(allocator, "call_{d}", .{index}),
            }
        else
            try std.fmt.allocPrint(allocator, "call_{d}", .{index});
        errdefer allocator.free(id);

        try calls.append(allocator, .{
            .id = id,
            .name = try allocator.dupe(u8, name),
            .arguments_json = arguments_json,
        });
    }

    if (calls.items.len == 0) {
        calls.deinit(allocator);
        return null;
    }
    return try calls.toOwnedSlice(allocator);
}

fn parseToolArgumentsJsonAlloc(
    allocator: std.mem.Allocator,
    function_obj: std.json.ObjectMap,
) ![]u8 {
    const arguments_value = function_obj.get("arguments") orelse return try allocator.dupe(u8, "{}");
    return switch (arguments_value) {
        .string => |value| try allocator.dupe(u8, value),
        .object => try jsonValueStringifyAlloc(allocator, arguments_value),
        else => try allocator.dupe(u8, "{}"),
    };
}

fn extractErrorMessage(root: std.json.ObjectMap) ?[]const u8 {
    const error_value = root.get("error") orelse return null;

    return switch (error_value) {
        .object => |error_object| switch (error_object.get("message") orelse return null) {
            .string => |message| message,
            else => null,
        },
        .string => |message| message,
        else => null,
    };
}

fn renderPayloadJsonAlloc(
    allocator: std.mem.Allocator,
    model_name: []const u8,
    request: types.Request,
) ![]u8 {
    const escaped_model = try escapeJsonStringAlloc(allocator, model_name);
    defer allocator.free(escaped_model);

    const messages_json = try renderMessagesJsonAlloc(allocator, request.messages);
    defer allocator.free(messages_json);

    const tool_choice_json = if (request.tool_choice) |tool_choice| blk: {
        const escaped_tool_choice = try escapeJsonStringAlloc(allocator, tool_choice);
        defer allocator.free(escaped_tool_choice);
        break :blk try std.fmt.allocPrint(allocator, ",\"tool_choice\":\"{s}\"", .{escaped_tool_choice});
    } else try allocator.dupe(u8, "");
    defer allocator.free(tool_choice_json);

    const tools_json = if (request.tools.len > 0) blk: {
        const rendered_tools = try renderToolsJsonAlloc(allocator, request.tools);
        defer allocator.free(rendered_tools);
        break :blk try std.fmt.allocPrint(allocator, ",\"tools\":{s}", .{rendered_tools});
    } else try allocator.dupe(u8, "");
    defer allocator.free(tools_json);

    return try std.fmt.allocPrint(
        allocator,
        "{{\"model\":\"{s}\",\"messages\":{s},\"stream\":false{s}{s}}}",
        .{ escaped_model, messages_json, tools_json, tool_choice_json },
    );
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

fn renderMessagesJsonAlloc(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try out.append(allocator, '[');
    for (messages, 0..) |message, index| {
        if (index > 0) try out.append(allocator, ',');

        const escaped_role = try escapeJsonStringAlloc(allocator, message.role);
        defer allocator.free(escaped_role);
        const escaped_content = try escapeJsonStringAlloc(allocator, message.content);
        defer allocator.free(escaped_content);

        try out.writer(allocator).print(
            "{{\"role\":\"{s}\",\"content\":\"{s}\"}}",
            .{ escaped_role, escaped_content },
        );
    }

    try out.append(allocator, ']');
    return try out.toOwnedSlice(allocator);
}

fn renderToolsJsonAlloc(
    allocator: std.mem.Allocator,
    tools: []const types.Tool,
) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try out.append(allocator, '[');
    for (tools, 0..) |tool, index| {
        if (index > 0) try out.append(allocator, ',');

        const escaped_name = try escapeJsonStringAlloc(allocator, tool.name);
        defer allocator.free(escaped_name);
        const escaped_description = try escapeJsonStringAlloc(allocator, tool.description);
        defer allocator.free(escaped_description);

        try out.writer(allocator).print(
            "{{\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"description\":\"{s}\"",
            .{ escaped_name, escaped_description },
        );
        if (tool.parameters_json) |parameters_json| {
            try out.writer(allocator).print(",\"parameters\":{s}", .{parameters_json});
        }
        try out.appendSlice(allocator, "}}}");
    }

    try out.append(allocator, ']');
    return try out.toOwnedSlice(allocator);
}

fn jsonValueStringifyAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    var json_writer = std.json.Stringify{
        .writer = &out.writer,
        .options = .{},
    };
    try json_writer.write(value);
    return try out.toOwnedSlice();
}

fn makeFailureResponse(
    allocator: std.mem.Allocator,
    model_name: []const u8,
    message: []const u8,
) !types.Response {
    return .{
        .id = null,
        .model = try allocator.dupe(u8, model_name),
        .output = try allocator.dupe(u8, message),
        .finish_reason = try allocator.dupe(u8, "stop"),
        .success = false,
        .usage = .{},
    };
}

fn parseUsageField(value: ?std.json.Value) usize {
    const actual = value orelse return 0;
    return switch (actual) {
        .integer => |number| if (number < 0) 0 else @as(usize, @intCast(number)),
        .float => |number| if (number < 0) 0 else @as(usize, @intFromFloat(number)),
        else => 0,
    };
}

test "buildUrl normalizes OpenAI-compatible v1 path variants" {
    const allocator = std.testing.allocator;

    const direct = try buildUrl(allocator, "https://openrouter.ai/api/v1", "/chat/completions");
    defer allocator.free(direct);
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1/chat/completions", direct);

    const slash = try buildUrl(allocator, "https://openrouter.ai/api/v1/", "/chat/completions");
    defer allocator.free(slash);
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1/chat/completions", slash);

    const no_v1 = try buildUrl(allocator, "https://openrouter.ai/api", "/chat/completions");
    defer allocator.free(no_v1);
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1/chat/completions", no_v1);
}

test "parseChatResponse surfaces OpenRouter-style upstream JSON errors" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"error":{"message":"rate limit exceeded"}}
    ;

    const response = try parseChatResponse(
        allocator,
        "openrouter/auto",
        "OpenRouter",
        .too_many_requests,
        raw,
    );
    defer response.deinit(allocator);

    try std.testing.expect(!response.success);
    try std.testing.expectEqualStrings("OpenRouter returned HTTP 429: rate limit exceeded", response.output);
}

test "parseChatResponse keeps ids and usage for successful responses" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"id":"chatcmpl-123","model":"openrouter/my-model","choices":[{"message":{"content":"hello"},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}
    ;

    const response = try parseChatResponse(
        allocator,
        "openrouter/auto",
        "OpenRouter",
        .ok,
        raw,
    );
    defer response.deinit(allocator);

    try std.testing.expect(response.success);
    try std.testing.expectEqualStrings("chatcmpl-123", response.id.?);
    try std.testing.expectEqualStrings("openrouter/my-model", response.model);
    try std.testing.expectEqualStrings("hello", response.output);
    try std.testing.expectEqual(@as(usize, 5), response.usage.total_tokens);
}

test "parseChatResponse preserves OpenAI tool calls" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"id":"chatcmpl-tools","model":"gpt-test","choices":[{"message":{"content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"echo","arguments":"{\"message\":\"demo-green\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}
    ;

    const response = try parseChatResponse(
        allocator,
        "gpt-test",
        "OpenAI",
        .ok,
        raw,
    );
    defer response.deinit(allocator);

    try std.testing.expect(response.success);
    try std.testing.expectEqualStrings("", response.output);
    try std.testing.expectEqualStrings("tool_calls", response.finish_reason);
    try std.testing.expect(response.tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), response.tool_calls.?.len);
    try std.testing.expectEqualStrings("call_1", response.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("echo", response.tool_calls.?[0].name);
    try std.testing.expectEqualStrings("{\"message\":\"demo-green\"}", response.tool_calls.?[0].arguments_json);
}

const std = @import("std");
const config = @import("../config.zig");
const types = @import("../types.zig");

pub fn callOpenRouter(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    request: types.Request,
) !types.Response {
    if (app_config.openrouter_api_key.len == 0) {
        return try errorResponse(
            allocator,
            request.model orelse app_config.openrouter_model,
            "OpenRouter provider selected but OPENROUTER_API_KEY is not set",
        );
    }

    const model_name = request.model orelse app_config.openrouter_model;

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri_text = try buildChatCompletionsUrl(allocator, app_config.openrouter_base_url);
    defer allocator.free(uri_text);

    const uri = try std.Uri.parse(uri_text);

    const escaped_model = try escapeJsonStringAlloc(allocator, model_name);
    defer allocator.free(escaped_model);

    const messages_json = try renderMessagesJsonAlloc(allocator, request.messages);
    defer allocator.free(messages_json);

    const body = try std.fmt.allocPrint(
        allocator,
        \\{{"model":"{s}","messages":{s},"stream":false}}
    , .{
        escaped_model,
        messages_json,
    });
    defer allocator.free(body);

    const bearer_value = try std.fmt.allocPrint(
        allocator,
        "Bearer {s}",
        .{app_config.openrouter_api_key},
    );
    defer allocator.free(bearer_value);

    var headers = std.ArrayList(std.http.Header){};
    defer headers.deinit(allocator);

    try headers.append(allocator, .{ .name = "content-type", .value = "application/json" });
    try headers.append(allocator, .{ .name = "authorization", .value = bearer_value });

    if (app_config.openrouter_http_referer.len > 0) {
        try headers.append(allocator, .{
            .name = "http-referer",
            .value = app_config.openrouter_http_referer,
        });
    }

    if (app_config.openrouter_app_name.len > 0) {
        try headers.append(allocator, .{
            .name = "x-openrouter-title",
            .value = app_config.openrouter_app_name,
        });
    }

    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    const result = try client.fetch(.{
        .location = .{ .uri = uri },
        .method = .POST,
        .extra_headers = headers.items,
        .payload = body,
        .response_writer = &writer.writer,
    });

    const raw = writer.written();
    return try parseOpenRouterResponse(
        allocator,
        model_name,
        result.status == .ok,
        raw,
    );
}

fn buildChatCompletionsUrl(
    allocator: std.mem.Allocator,
    base_url: []const u8,
) ![]u8 {
    if (std.mem.endsWith(u8, base_url, "/")) {
        return try std.fmt.allocPrint(allocator, "{s}chat/completions", .{base_url});
    }

    return try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{base_url});
}

fn parseOpenRouterResponse(
    allocator: std.mem.Allocator,
    fallback_model: []const u8,
    is_http_ok: bool,
    raw: []const u8,
) !types.Response {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
        if (is_http_ok) {
            return try errorResponse(
                allocator,
                fallback_model,
                "OpenRouter returned invalid JSON",
            );
        }

        return try errorResponse(
            allocator,
            fallback_model,
            "OpenRouter returned a non-JSON error response",
        );
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return try errorResponse(
            allocator,
            fallback_model,
            "OpenRouter returned an invalid response object",
        ),
    };

    if (extractErrorMessage(root)) |message| {
        return try errorResponse(allocator, fallback_model, message);
    }

    if (!is_http_ok) {
        return try errorResponse(
            allocator,
            fallback_model,
            "OpenRouter request failed",
        );
    }

    const id_value = if (root.get("id")) |id_field|
        switch (id_field) {
            .string => |value| value,
            else => null,
        }
    else
        null;

    const model_value = if (root.get("model")) |model_field|
        switch (model_field) {
            .string => |value| value,
            else => fallback_model,
        }
    else
        fallback_model;

    const choices_value = switch (root.get("choices") orelse {
        return try errorResponse(allocator, fallback_model, "OpenRouter response is missing choices");
    }) {
        .array => |value| value,
        else => return try errorResponse(allocator, fallback_model, "OpenRouter response choices are invalid"),
    };

    if (choices_value.items.len == 0) {
        return try errorResponse(allocator, fallback_model, "OpenRouter response choices are empty");
    }

    const choice = switch (choices_value.items[0]) {
        .object => |value| value,
        else => return try errorResponse(allocator, fallback_model, "OpenRouter choice is invalid"),
    };

    const message_object = switch (choice.get("message") orelse {
        return try errorResponse(allocator, fallback_model, "OpenRouter response is missing assistant message");
    }) {
        .object => |value| value,
        else => return try errorResponse(allocator, fallback_model, "OpenRouter assistant message is invalid"),
    };

    const content_value = switch (message_object.get("content") orelse {
        return try errorResponse(allocator, fallback_model, "OpenRouter assistant content is missing");
    }) {
        .string => |value| value,
        else => return try errorResponse(allocator, fallback_model, "OpenRouter assistant content is invalid"),
    };

    const finish_reason_value = if (choice.get("finish_reason")) |finish_reason|
        switch (finish_reason) {
            .string => |value| value,
            else => "stop",
        }
    else
        "stop";

    return .{
        .id = if (id_value) |value| try allocator.dupe(u8, value) else null,
        .model = try allocator.dupe(u8, model_value),
        .output = try allocator.dupe(u8, content_value),
        .finish_reason = try allocator.dupe(u8, finish_reason_value),
        .success = true,
        .usage = extractUsage(root),
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

fn extractUsage(root: std.json.ObjectMap) types.Usage {
    const usage_value = root.get("usage") orelse return .{};

    const usage_object = switch (usage_value) {
        .object => |value| value,
        else => return .{},
    };

    return .{
        .prompt_tokens = parseUsageField(usage_object.get("prompt_tokens")),
        .completion_tokens = parseUsageField(usage_object.get("completion_tokens")),
        .total_tokens = parseUsageField(usage_object.get("total_tokens")),
    };
}

fn parseUsageField(value: ?std.json.Value) usize {
    const actual_value = value orelse return 0;

    return switch (actual_value) {
        .integer => |number| if (number < 0) 0 else @intCast(number),
        .float => |number| if (number < 0) 0 else @intFromFloat(number),
        else => 0,
    };
}

fn errorResponse(
    allocator: std.mem.Allocator,
    model: []const u8,
    message: []const u8,
) !types.Response {
    return .{
        .id = null,
        .model = try allocator.dupe(u8, model),
        .output = try allocator.dupe(u8, message),
        .finish_reason = try allocator.dupe(u8, "error"),
        .success = false,
        .usage = .{},
    };
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
        if (index > 0) {
            try out.append(allocator, ',');
        }

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

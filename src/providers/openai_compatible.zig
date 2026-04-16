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

    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    const fetch_result = try client.fetch(.{
        .location = .{ .uri = uri },
        .method = .POST,
        .extra_headers = headers.items,
        .payload = payload,
        .response_writer = &writer.writer,
    });

    if (fetch_result.status != .ok) {
        const error_message = try std.fmt.allocPrint(
            allocator,
            "{s} returned HTTP {d}",
            .{ provider_label, @intFromEnum(fetch_result.status) },
        );
        defer allocator.free(error_message);

        return try makeFailureResponse(
            allocator,
            model_name,
            error_message,
        );
    }

    const raw = writer.written();
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |value| value,
        else => return try makeFailureResponse(allocator, model_name, "Provider response was not a JSON object"),
    };

    const choices = switch (root.get("choices") orelse {
        return try makeFailureResponse(allocator, model_name, "Provider response missing choices");
    }) {
        .array => |value| value,
        else => return try makeFailureResponse(allocator, model_name, "Provider choices was not an array"),
    };

    if (choices.items.len == 0) {
        return try makeFailureResponse(allocator, model_name, "Provider choices array was empty");
    }

    const first_choice = switch (choices.items[0]) {
        .object => |value| value,
        else => return try makeFailureResponse(allocator, model_name, "Provider choice was not an object"),
    };

    const message_obj = switch (first_choice.get("message") orelse {
        return try makeFailureResponse(allocator, model_name, "Provider choice missing message");
    }) {
        .object => |value| value,
        else => return try makeFailureResponse(allocator, model_name, "Provider message was not an object"),
    };

    const output = switch (message_obj.get("content") orelse {
        return try makeFailureResponse(allocator, model_name, "Provider message missing content");
    }) {
        .string => |value| value,
        else => return try makeFailureResponse(allocator, model_name, "Provider content was not a string"),
    };

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
        .id = null,
        .model = try allocator.dupe(u8, model_name),
        .output = try allocator.dupe(u8, output),
        .finish_reason = try allocator.dupe(u8, finish_reason),
        .success = true,
        .usage = usage,
    };
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
            "{{\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"description\":\"{s}\"}}}}",
            .{ escaped_name, escaped_description },
        );
    }

    try out.append(allocator, ']');
    return try out.toOwnedSlice(allocator);
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

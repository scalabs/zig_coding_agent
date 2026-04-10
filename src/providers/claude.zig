const std = @import("std");
const config = @import("../config.zig");
const types = @import("../types.zig");

pub fn callClaude(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    request: types.Request,
) !types.Response {
    if (app_config.claude_api_key.len == 0) {
        return .{
            .id = null,
            .model = try allocator.dupe(u8, request.model orelse app_config.claude_model),
            .output = try allocator.dupe(u8, "CLAUDE_API_KEY is not configured on the server"),
            .finish_reason = try allocator.dupe(u8, "stop"),
            .success = false,
            .usage = .{},
        };
    }

    const model_name = request.model orelse app_config.claude_model;

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri_text = try buildMessagesUrl(allocator, app_config.claude_base_url);
    defer allocator.free(uri_text);
    const uri = try std.Uri.parse(uri_text);

    const payload = try renderClaudePayloadJsonAlloc(allocator, model_name, request.messages);
    defer allocator.free(payload);

    const auth_value = try std.fmt.allocPrint(allocator, "{s}", .{app_config.claude_api_key});
    defer allocator.free(auth_value);

    const headers = &[_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "x-api-key", .value = auth_value },
        .{ .name = "anthropic-version", .value = "2023-06-01" },
    };

    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    const fetch_result = try client.fetch(.{
        .location = .{ .uri = uri },
        .method = .POST,
        .extra_headers = headers,
        .payload = payload,
        .response_writer = &writer.writer,
    });

    if (fetch_result.status != .ok) {
        return .{
            .id = null,
            .model = try allocator.dupe(u8, model_name),
            .output = try std.fmt.allocPrint(allocator, "Claude returned HTTP {d}", .{@intFromEnum(fetch_result.status)}),
            .finish_reason = try allocator.dupe(u8, "stop"),
            .success = false,
            .usage = .{},
        };
    }

    const raw = writer.written();
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |value| value,
        else => return invalidClaudeResponse(allocator, model_name, "Claude response was not a JSON object"),
    };

    const content_value = switch (root.get("content") orelse {
        return invalidClaudeResponse(allocator, model_name, "Claude response missing content");
    }) {
        .array => |value| value,
        else => return invalidClaudeResponse(allocator, model_name, "Claude content was not an array"),
    };

    if (content_value.items.len == 0) {
        return invalidClaudeResponse(allocator, model_name, "Claude content array was empty");
    }

    const first_block = switch (content_value.items[0]) {
        .object => |value| value,
        else => return invalidClaudeResponse(allocator, model_name, "Claude content block was not an object"),
    };

    const text = switch (first_block.get("text") orelse {
        return invalidClaudeResponse(allocator, model_name, "Claude content block missing text");
    }) {
        .string => |value| value,
        else => return invalidClaudeResponse(allocator, model_name, "Claude text was not a string"),
    };

    const usage = if (root.get("usage")) |usage_value|
        switch (usage_value) {
            .object => |usage_obj| types.Usage{
                .prompt_tokens = parseUsageField(usage_obj.get("input_tokens")),
                .completion_tokens = parseUsageField(usage_obj.get("output_tokens")),
                .total_tokens = parseUsageField(usage_obj.get("input_tokens")) + parseUsageField(usage_obj.get("output_tokens")),
            },
            else => types.Usage{},
        }
    else
        types.Usage{};

    return .{
        .id = null,
        .model = try allocator.dupe(u8, model_name),
        .output = try allocator.dupe(u8, text),
        .finish_reason = try allocator.dupe(u8, "stop"),
        .success = true,
        .usage = usage,
    };
}

fn buildMessagesUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, base_url, "/v1")) return try std.fmt.allocPrint(allocator, "{s}/messages", .{base_url});
    if (std.mem.endsWith(u8, base_url, "/v1/")) return try std.fmt.allocPrint(allocator, "{s}messages", .{base_url});
    if (std.mem.endsWith(u8, base_url, "/")) return try std.fmt.allocPrint(allocator, "{s}v1/messages", .{base_url});
    return try std.fmt.allocPrint(allocator, "{s}/v1/messages", .{base_url});
}

fn renderClaudePayloadJsonAlloc(
    allocator: std.mem.Allocator,
    model_name: []const u8,
    messages: []const types.Message,
) ![]u8 {
    var system_prompt = std.ArrayList(u8){};
    defer system_prompt.deinit(allocator);

    var rendered_messages = std.ArrayList(u8){};
    defer rendered_messages.deinit(allocator);

    try rendered_messages.append(allocator, '[');
    var wrote_message = false;

    for (messages) |message| {
        if (std.ascii.eqlIgnoreCase(message.role, "system")) {
            if (system_prompt.items.len > 0) {
                try system_prompt.appendSlice(allocator, "\n");
            }
            try system_prompt.appendSlice(allocator, message.content);
            continue;
        }

        if (wrote_message) {
            try rendered_messages.append(allocator, ',');
        }
        wrote_message = true;

        const escaped_role = if (std.ascii.eqlIgnoreCase(message.role, "assistant"))
            try allocator.dupe(u8, "assistant")
        else
            try allocator.dupe(u8, "user");
        defer allocator.free(escaped_role);

        const escaped_content = try escapeJsonStringAlloc(allocator, message.content);
        defer allocator.free(escaped_content);

        try rendered_messages.writer(allocator).print(
            "{{\"role\":\"{s}\",\"content\":\"{s}\"}}",
            .{ escaped_role, escaped_content },
        );
    }

    if (!wrote_message) {
        const fallback = try escapeJsonStringAlloc(allocator, "Continue.");
        defer allocator.free(fallback);
        try rendered_messages.writer(allocator).print("{{\"role\":\"user\",\"content\":\"{s}\"}}", .{fallback});
    }

    try rendered_messages.append(allocator, ']');

    const escaped_model = try escapeJsonStringAlloc(allocator, model_name);
    defer allocator.free(escaped_model);

    const system_json = if (system_prompt.items.len > 0) blk: {
        const escaped_system = try escapeJsonStringAlloc(allocator, system_prompt.items);
        defer allocator.free(escaped_system);
        break :blk try std.fmt.allocPrint(allocator, ",\"system\":\"{s}\"", .{escaped_system});
    } else try allocator.dupe(u8, "");
    defer allocator.free(system_json);

    return try std.fmt.allocPrint(
        allocator,
        "{{\"model\":\"{s}\",\"max_tokens\":1024,\"messages\":{s}{s}}}",
        .{ escaped_model, rendered_messages.items, system_json },
    );
}

fn invalidClaudeResponse(
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

fn parseUsageField(value: ?std.json.Value) usize {
    const actual = value orelse return 0;
    return switch (actual) {
        .integer => |number| if (number < 0) 0 else @as(usize, @intCast(number)),
        .float => |number| if (number < 0) 0 else @as(usize, @intFromFloat(number)),
        else => 0,
    };
}

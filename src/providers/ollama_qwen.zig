//! Ollama-backed provider adapter for chat completion requests.
const std = @import("std");
const config = @import("../config.zig");
const types = @import("../types.zig");

/// Sends a chat request to Ollama /api/chat and normalizes the response.
///
/// Args:
/// - allocator: allocator used for HTTP payloads and returned response ownership.
/// - app_config: runtime config containing Ollama base URL and default model.
/// - request: validated normalized request with conversation messages.
///
/// Errors:
/// - propagates allocation, URI parsing, HTTP fetch, and JSON parse failures.
pub fn callQwen(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    request: types.Request,
) !types.Response {
    const model_name = request.model orelse app_config.ollama_model;

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri_text = try buildChatUrl(allocator, app_config.ollama_base_url);
    defer allocator.free(uri_text);

    const uri = try std.Uri.parse(uri_text);

    const messages_json = try renderMessagesJsonAlloc(allocator, request.messages);
    defer allocator.free(messages_json);

    const body = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "model": "{s}",
        \\  "messages": {s},
        \\  "stream": false
        \\}}
    , .{ model_name, messages_json });
    defer allocator.free(body);

    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    const headers = &[_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
    };

    const result = try client.fetch(.{
        .location = .{ .uri = uri },
        .method = .POST,
        .extra_headers = headers,
        .payload = body,
        .response_writer = &writer.writer,
    });

    if (result.status != .ok) {
        return try makeResponse(allocator, model_name, "HTTP error from Ollama", false);
    }

    const raw = writer.written();

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |value| value,
        else => return try makeResponse(
            allocator,
            model_name,
            "Invalid JSON from Ollama",
            false,
        ),
    };

    const message_value = root.get("message") orelse {
        return try makeResponse(
            allocator,
            model_name,
            "Missing message field from Ollama",
            false,
        );
    };

    const message_object = switch (message_value) {
        .object => |value| value,
        else => return try makeResponse(
            allocator,
            model_name,
            "Invalid message field from Ollama",
            false,
        ),
    };

    const content_value = switch (message_object.get("content") orelse {
        return try makeResponse(
            allocator,
            model_name,
            "Missing content field from Ollama message",
            false,
        );
    }) {
        .string => |value| value,
        else => return try makeResponse(
            allocator,
            model_name,
            "Invalid content field from Ollama message",
            false,
        ),
    };

    // Ollama may omit done_reason; default to `stop` for OpenAI compatibility.
    const finish_reason = if (root.get("done_reason")) |done_reason|
        switch (done_reason) {
            .string => |value| value,
            else => "stop",
        }
    else
        "stop";

    return .{
        .id = null,
        .model = try allocator.dupe(u8, model_name),
        .output = try allocator.dupe(u8, content_value),
        .finish_reason = try allocator.dupe(u8, finish_reason),
        .success = true,
        .usage = .{
            .prompt_tokens = parseUsageField(root.get("prompt_eval_count")),
            .completion_tokens = parseUsageField(root.get("eval_count")),
            .total_tokens = parseUsageField(root.get("prompt_eval_count")) +
                parseUsageField(root.get("eval_count")),
        },
    };
}

fn buildChatUrl(
    allocator: std.mem.Allocator,
    base_url: []const u8,
) ![]u8 {
    if (std.mem.endsWith(u8, base_url, "/")) {
        return try std.fmt.allocPrint(allocator, "{s}api/chat", .{base_url});
    }

    return try std.fmt.allocPrint(allocator, "{s}/api/chat", .{base_url});
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

fn makeResponse(
    allocator: std.mem.Allocator,
    model: []const u8,
    output: []const u8,
    success: bool,
) !types.Response {
    return .{
        .id = null,
        .model = try allocator.dupe(u8, model),
        .output = try allocator.dupe(u8, output),
        .finish_reason = try allocator.dupe(u8, "stop"),
        .success = success,
        .usage = .{},
    };
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

fn parseUsageField(value: ?std.json.Value) usize {
    const actual_value = value orelse return 0;

    return switch (actual_value) {
        .integer => |number| if (number < 0) 0 else @intCast(number),
        .float => |number| if (number < 0) 0 else @intFromFloat(number),
        else => 0,
    };
}

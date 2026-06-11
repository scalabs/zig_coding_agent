//! HTTP response builders for OpenAI-compatible success and error payloads.
const std = @import("std");
const types = @import("../types.zig");
const errors = @import("../backend/errors.zig");

/// Escapes a UTF-8 byte slice for safe JSON string embedding.
///
/// Args:
/// - allocator: allocator used for escaped output buffer.
/// - input: unescaped string bytes.
///
/// Returns:
/// - ![]u8: owned escaped string without surrounding quotes.
pub fn escapeJsonStringAlloc(
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

fn optionalJsonStringAlloc(
    allocator: std.mem.Allocator,
    value: ?[]const u8,
) ![]u8 {
    if (value) |text| {
        const escaped = try escapeJsonStringAlloc(allocator, text);
        defer allocator.free(escaped);

        return try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
    }

    return try allocator.dupe(u8, "null");
}

fn sendJson(
    connection: std.net.Server.Connection,
    status_code: u16,
    body: []const u8,
    request_id: ?[]const u8,
) !void {
    const status_text = switch (status_code) {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        413 => "Payload Too Large",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        502 => "Bad Gateway",
        else => "Internal Server Error",
    };

    const request_id_header = if (request_id) |id|
        try std.fmt.allocPrint(
            std.heap.page_allocator,
            "X-Request-Id: {s}\r\n",
            .{id},
        )
    else
        try std.heap.page_allocator.dupe(u8, "");
    defer std.heap.page_allocator.free(request_id_header);

    // The server handles one request per connection.
    const response = try std.fmt.allocPrint(
        std.heap.page_allocator,
        "HTTP/1.1 {d} {s}\r\n" ++
            "Content-Type: application/json\r\n" ++
            "{s}" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "{s}",
        .{ status_code, status_text, request_id_header, body.len, body },
    );
    defer std.heap.page_allocator.free(response);

    try connection.stream.writeAll(response);
}

pub fn sendJsonText(
    connection: std.net.Server.Connection,
    status_code: u16,
    body: []const u8,
) !void {
    try sendJson(connection, status_code, body, null);
}

pub fn sendJsonTextWithRequestId(
    connection: std.net.Server.Connection,
    status_code: u16,
    body: []const u8,
    request_id: []const u8,
) !void {
    try sendJson(connection, status_code, body, request_id);
}

/// Send API error response
pub fn sendApiError(
    connection: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    api_error: errors.ApiError,
    request_id: ?[]const u8,
) !void {
    const escaped_message = try escapeJsonStringAlloc(allocator, api_error.message);
    defer allocator.free(escaped_message);

    const param_json = try optionalJsonStringAlloc(allocator, api_error.param);
    defer allocator.free(param_json);

    const code_json = try optionalJsonStringAlloc(allocator, api_error.code);
    defer allocator.free(code_json);

    const response_json = try std.fmt.allocPrint(allocator,
        \\{{"error":{{"message":"{s}","type":"{s}","param":{s},"code":{s}}}}}
    , .{
        escaped_message,
        api_error.error_type,
        param_json,
        code_json,
    });
    defer allocator.free(response_json);

    try sendJson(connection, api_error.status_code, response_json, request_id);
}

fn makeCompletionIdAlloc(allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "chatcmpl-{d}",
        .{std.time.microTimestamp()},
    );
}

/// Serializes and sends OpenAI-compatible chat completion payload.
///
/// Args:
/// - connection: destination client connection.
/// - allocator: allocator used for temporary JSON assembly buffers.
/// - result: normalized provider response.
///
/// Returns:
/// - !void: success when completion payload is written.
pub fn sendChatCompletion(
    connection: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    result: types.Response,
    request_id: ?[]const u8,
) !void {
    var generated_id: ?[]u8 = null;
    defer if (generated_id) |id| allocator.free(id);

    // Preserve provider-supplied IDs, otherwise generate one.
    const completion_id = if (result.id) |id|
        id
    else blk: {
        generated_id = try makeCompletionIdAlloc(allocator);
        break :blk generated_id.?;
    };

    const escaped_id = try escapeJsonStringAlloc(allocator, completion_id);
    defer allocator.free(escaped_id);

    const escaped_model = try escapeJsonStringAlloc(allocator, result.model);
    defer allocator.free(escaped_model);

    const escaped_content = try escapeJsonStringAlloc(allocator, result.output);
    defer allocator.free(escaped_content);

    const tool_calls_json = try renderToolCallsSuffixJsonAlloc(allocator, result.tool_calls);
    defer allocator.free(tool_calls_json);

    const escaped_finish_reason = try escapeJsonStringAlloc(allocator, result.finish_reason);
    defer allocator.free(escaped_finish_reason);

    const response_json = try std.fmt.allocPrint(allocator,
        \\{{"id":"{s}","object":"chat.completion","created":{d},"model":"{s}","choices":[{{"index":0,"message":{{"role":"assistant","content":"{s}"{s}}},"finish_reason":"{s}"}}],"usage":{{"prompt_tokens":{d},"completion_tokens":{d},"total_tokens":{d}}}}}
    , .{
        escaped_id,
        std.time.timestamp(),
        escaped_model,
        escaped_content,
        tool_calls_json,
        escaped_finish_reason,
        result.usage.prompt_tokens,
        result.usage.completion_tokens,
        result.usage.total_tokens,
    });
    defer allocator.free(response_json);

    try sendJson(connection, 200, response_json, request_id);
}

fn renderToolCallsSuffixJsonAlloc(
    allocator: std.mem.Allocator,
    tool_calls: ?[]const types.ToolCall,
) ![]u8 {
    const calls = tool_calls orelse return try allocator.dupe(u8, "");
    if (calls.len == 0) return try allocator.dupe(u8, "");

    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, ",\"tool_calls\":[");
    for (calls, 0..) |call, index| {
        if (index > 0) try out.append(allocator, ',');

        const escaped_id = try escapeJsonStringAlloc(allocator, call.id);
        defer allocator.free(escaped_id);
        const escaped_name = try escapeJsonStringAlloc(allocator, call.name);
        defer allocator.free(escaped_name);
        const escaped_arguments = try escapeJsonStringAlloc(allocator, call.arguments_json);
        defer allocator.free(escaped_arguments);

        try out.writer(allocator).print(
            "{{\"id\":\"{s}\",\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"arguments\":\"{s}\"}}}}",
            .{ escaped_id, escaped_name, escaped_arguments },
        );
    }
    try out.append(allocator, ']');
    return try out.toOwnedSlice(allocator);
}

test "renderToolCallsSuffixJsonAlloc emits OpenAI tool calls" {
    const allocator = std.testing.allocator;
    const calls = [_]types.ToolCall{
        .{
            .id = try allocator.dupe(u8, "call_1"),
            .name = try allocator.dupe(u8, "echo"),
            .arguments_json = try allocator.dupe(u8, "{\"message\":\"demo-green\"}"),
        },
    };
    defer calls[0].deinit(allocator);

    const rendered = try renderToolCallsSuffixJsonAlloc(allocator, calls[0..]);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"tool_calls\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"name\":\"echo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\\\"message\\\":\\\"demo-green\\\"") != null);
}

pub fn sendEventStreamHeaders(connection: std.net.Server.Connection, request_id: ?[]const u8) !void {
    const request_id_header = if (request_id) |id|
        try std.fmt.allocPrint(
            std.heap.page_allocator,
            "X-Request-Id: {s}\r\n",
            .{id},
        )
    else
        try std.heap.page_allocator.dupe(u8, "");
    defer std.heap.page_allocator.free(request_id_header);

    const response = try std.fmt.allocPrint(
        std.heap.page_allocator,
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/event-stream\r\n" ++
            "Cache-Control: no-cache\r\n" ++
            "{s}" ++
            "Connection: close\r\n" ++
            "X-Accel-Buffering: no\r\n" ++
            "\r\n",
        .{request_id_header},
    );
    defer std.heap.page_allocator.free(response);

    try connection.stream.writeAll(response);
}

pub fn sendSseData(connection: std.net.Server.Connection, payload: []const u8) !void {
    const frame = try std.fmt.allocPrint(
        std.heap.page_allocator,
        "data: {s}\n\n",
        .{payload},
    );
    defer std.heap.page_allocator.free(frame);

    try connection.stream.writeAll(frame);
}

pub fn sendSseDone(connection: std.net.Server.Connection) !void {
    try connection.stream.writeAll("data: [DONE]\n\n");
}

pub fn sendChatCompletionChunkSse(
    connection: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    completion_id: []const u8,
    model: []const u8,
    delta_content: ?[]const u8,
    finish_reason: ?[]const u8,
) !void {
    const escaped_id = try escapeJsonStringAlloc(allocator, completion_id);
    defer allocator.free(escaped_id);

    const escaped_model = try escapeJsonStringAlloc(allocator, model);
    defer allocator.free(escaped_model);

    const delta_json = if (delta_content) |text| blk: {
        const escaped = try escapeJsonStringAlloc(allocator, text);
        defer allocator.free(escaped);
        break :blk try std.fmt.allocPrint(allocator, "{{\"content\":\"{s}\"}}", .{escaped});
    } else try allocator.dupe(u8, "{}");
    defer allocator.free(delta_json);

    const finish_reason_json = try optionalJsonStringAlloc(allocator, finish_reason);
    defer allocator.free(finish_reason_json);

    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"{s}\",\"object\":\"chat.completion.chunk\",\"created\":{d},\"model\":\"{s}\",\"choices\":[{{\"index\":0,\"delta\":{s},\"finish_reason\":{s}}}]}}",
        .{
            escaped_id,
            std.time.timestamp(),
            escaped_model,
            delta_json,
            finish_reason_json,
        },
    );
    defer allocator.free(payload);

    try sendSseData(connection, payload);
}

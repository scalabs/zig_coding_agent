const std = @import("std");
const types = @import("../types.zig");
const errors = @import("../backend/errors.zig");

/// Escape special characters for JSON strings
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

/// Convert optional string to JSON null or quoted string
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

/// Send HTTP response with JSON body
fn sendJson(
    connection: std.net.Server.Connection,
    status_code: u16,
    body: []const u8,
) !void {
    const status_text = switch (status_code) {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        413 => "Payload Too Large",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        else => "Internal Server Error",
    };

    const response = try std.fmt.allocPrint(
        std.heap.page_allocator,
        "HTTP/1.1 {d} {s}\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "{s}",
        .{ status_code, status_text, body.len, body },
    );
    defer std.heap.page_allocator.free(response);

    try connection.stream.writeAll(response);
}

pub fn sendJsonText(
    connection: std.net.Server.Connection,
    status_code: u16,
    body: []const u8,
) !void {
    try sendJson(connection, status_code, body);
}

/// Send API error response
pub fn sendApiError(
    connection: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    api_error: errors.ApiError,
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

    try sendJson(connection, api_error.status_code, response_json);
}

/// Generate completion ID from current timestamp
fn makeCompletionIdAlloc(allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "chatcmpl-{d}",
        .{std.time.microTimestamp()},
    );
}

/// Send chat completion response
pub fn sendChatCompletion(
    connection: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    result: types.Response,
) !void {
    var generated_id: ?[]u8 = null;
    defer if (generated_id) |id| allocator.free(id);

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

    const escaped_finish_reason = try escapeJsonStringAlloc(allocator, result.finish_reason);
    defer allocator.free(escaped_finish_reason);

    const response_json = try std.fmt.allocPrint(allocator,
        \\{{"id":"{s}","object":"chat.completion","created":{d},"model":"{s}","choices":[{{"index":0,"message":{{"role":"assistant","content":"{s}"}},"finish_reason":"{s}"}}],"usage":{{"prompt_tokens":{d},"completion_tokens":{d},"total_tokens":{d}}}}}
    , .{
        escaped_id,
        std.time.timestamp(),
        escaped_model,
        escaped_content,
        escaped_finish_reason,
        result.usage.prompt_tokens,
        result.usage.completion_tokens,
        result.usage.total_tokens,
    });
    defer allocator.free(response_json);

    try sendJson(connection, 200, response_json);
}

pub fn sendEventStreamHeaders(connection: std.net.Server.Connection) !void {
    const response =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/event-stream\r\n" ++
        "Cache-Control: no-cache\r\n" ++
        "Connection: close\r\n" ++
        "X-Accel-Buffering: no\r\n" ++
        "\r\n";

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

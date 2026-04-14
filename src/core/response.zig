//! HTTP response builders for OpenAI-compatible success and error payloads.
const std = @import("std");
const types = @import("../types.zig");
const errors = @import("../backend/errors.zig");

/// Serializes any JSON-compatible value to an owned JSON token.
///
/// Args:
/// - allocator: allocator used for output buffer.
/// - value: JSON-compatible value to serialize.
///
/// Returns:
/// - ![]u8: owned JSON token string.
fn jsonValueAlloc(
    allocator: std.mem.Allocator,
    value: anytype,
) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
}

fn optionalJsonStringAlloc(
    allocator: std.mem.Allocator,
    value: ?[]const u8,
) ![]u8 {
    return try jsonValueAlloc(allocator, value);
}

fn sendJson(
    connection: std.net.Server.Connection,
    status_code: u16,
    body: []const u8,
) !void {
    const status_text = switch (status_code) {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        413 => "Payload Too Large",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        else => "Internal Server Error",
    };

    // The server handles one request per connection.
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

/// Serializes and sends OpenAI-style API error JSON.
///
/// Args:
/// - connection: destination client connection.
/// - allocator: allocator used for temporary escaped fields and payload.
/// - api_error: normalized error shape to serialize.
///
/// Returns:
/// - !void: success when error response is written.
pub fn sendApiError(
    connection: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    api_error: errors.ApiError,
) !void {
    const message_json = try jsonValueAlloc(allocator, api_error.message);
    defer allocator.free(message_json);

    const type_json = try jsonValueAlloc(allocator, api_error.error_type);
    defer allocator.free(type_json);

    const param_json = try optionalJsonStringAlloc(allocator, api_error.param);
    defer allocator.free(param_json);

    const code_json = try optionalJsonStringAlloc(allocator, api_error.code);
    defer allocator.free(code_json);

    const response_json = try std.fmt.allocPrint(allocator,
        \\{{"error":{{"message":{s},"type":{s},"param":{s},"code":{s}}}}}
    , .{
        message_json,
        type_json,
        param_json,
        code_json,
    });
    defer allocator.free(response_json);

    try sendJson(connection, api_error.status_code, response_json);
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

    const id_json = try jsonValueAlloc(allocator, completion_id);
    defer allocator.free(id_json);

    const model_json = try jsonValueAlloc(allocator, result.model);
    defer allocator.free(model_json);

    const content_json = try jsonValueAlloc(allocator, result.output);
    defer allocator.free(content_json);

    const finish_reason_json = try jsonValueAlloc(allocator, result.finish_reason);
    defer allocator.free(finish_reason_json);

    const response_json = try std.fmt.allocPrint(allocator,
        \\{{"id":{s},"object":"chat.completion","created":{d},"model":{s},"choices":[{{"index":0,"message":{{"role":"assistant","content":{s}}},"finish_reason":{s}}}],"usage":{{"prompt_tokens":{d},"completion_tokens":{d},"total_tokens":{d}}}}}
    , .{
        id_json,
        std.time.timestamp(),
        model_json,
        content_json,
        finish_reason_json,
        result.usage.prompt_tokens,
        result.usage.completion_tokens,
        result.usage.total_tokens,
    });
    defer allocator.free(response_json);

    try sendJson(connection, 200, response_json);
}

test "jsonValueAlloc round-trips control characters" {
    const allocator = std.testing.allocator;
    const raw = "line1\x01line2\nline3\r\x0b\x0c";

    const encoded = try jsonValueAlloc(allocator, raw);
    defer allocator.free(encoded);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();

    const value = switch (parsed.value) {
        .string => |string| string,
        else => return error.UnexpectedJsonType,
    };

    try std.testing.expectEqualStrings(raw, value);
}

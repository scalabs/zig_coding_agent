//! Minimal route matcher for the HTTP request line.
const std = @import("std");

/// Matches only `POST /v1/chat/completions` and validates request-line shape.
///
/// Args:
/// - request_raw: full raw HTTP request bytes.
///
/// Errors:
/// - returns `error.InvalidHttpRequest` when request line cannot be parsed.
pub fn matchChatCompletionsRoute(request_raw: []const u8) !bool {
    const request_line_end = std.mem.indexOf(u8, request_raw, "\r\n") orelse {
        return error.InvalidHttpRequest;
    };
    const request_line = request_raw[0..request_line_end];

    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse return error.InvalidHttpRequest;
    const target = parts.next() orelse return error.InvalidHttpRequest;
    _ = parts.next() orelse return error.InvalidHttpRequest;

    if (parts.next() != null) {
        return error.InvalidHttpRequest;
    }

    return std.mem.eql(u8, method, "POST") and
        std.mem.eql(u8, target, "/v1/chat/completions");
}

test "matchChatCompletionsRoute only accepts POST chat completions" {
    try std.testing.expect(try matchChatCompletionsRoute(
        "POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\n\r\n",
    ));
    try std.testing.expect(!(try matchChatCompletionsRoute(
        "GET /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\n\r\n",
    )));
    try std.testing.expect(!(try matchChatCompletionsRoute(
        "POST /health HTTP/1.1\r\nHost: localhost\r\n\r\n",
    )));
}

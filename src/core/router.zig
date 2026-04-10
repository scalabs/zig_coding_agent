const std = @import("std");

pub const Route = enum {
    chat_completions,
    health,
    metrics,
    diagnostics_clients,
    diagnostics_requests,
};

pub fn parseRoute(request_raw: []const u8) !?Route {
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

    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, target, "/v1/chat/completions")) {
        return .chat_completions;
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, target, "/health")) {
        return .health;
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, target, "/metrics")) {
        return .metrics;
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, target, "/diagnostics/clients")) {
        return .diagnostics_clients;
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, target, "/diagnostics/requests")) {
        return .diagnostics_requests;
    }

    return null;
}

/// Check if request is for POST /v1/chat/completions route
pub fn matchChatCompletionsRoute(request_raw: []const u8) !bool {
    const route = try parseRoute(request_raw);
    return route == .chat_completions;
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

test "parseRoute supports diagnostics endpoints" {
    try std.testing.expectEqual(Route.health, (try parseRoute("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")).?);
    try std.testing.expectEqual(Route.metrics, (try parseRoute("GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")).?);
    try std.testing.expectEqual(Route.diagnostics_clients, (try parseRoute("GET /diagnostics/clients HTTP/1.1\r\nHost: localhost\r\n\r\n")).?);
    try std.testing.expectEqual(Route.diagnostics_requests, (try parseRoute("GET /diagnostics/requests HTTP/1.1\r\nHost: localhost\r\n\r\n")).?);
}

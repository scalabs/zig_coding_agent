const std = @import("std");

pub const AuthResult = enum {
    allowed,
    denied,
};

pub fn authorizeRequest(
    required_api_key: []const u8,
    request_raw: []const u8,
) AuthResult {
    if (required_api_key.len == 0) return .allowed;

    const supplied_key = findApiKeyFromRequest(request_raw) orelse return .denied;
    if (std.mem.eql(u8, supplied_key, required_api_key)) return .allowed;
    return .denied;
}

pub fn findApiKeyFromRequest(request_raw: []const u8) ?[]const u8 {
    if (findHeaderValue(request_raw, "x-api-key")) |value| {
        return value;
    }

    const auth = findHeaderValue(request_raw, "authorization") orelse return null;
    const bearer_prefix = "Bearer ";
    if (std.mem.startsWith(u8, auth, bearer_prefix)) {
        return auth[bearer_prefix.len..];
    }
    return auth;
}

fn findHeaderValue(request_raw: []const u8, header_name: []const u8) ?[]const u8 {
    const request_line_end = std.mem.indexOf(u8, request_raw, "\r\n") orelse return null;
    const headers_start = request_line_end + 2;
    const headers_end = std.mem.indexOfPos(u8, request_raw, headers_start, "\r\n\r\n") orelse return null;
    const headers = request_raw[headers_start..headers_end];

    var lines = std.mem.splitScalar(u8, headers, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0) continue;

        const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..separator], " ");
        const value = std.mem.trim(u8, line[separator + 1 ..], " ");

        if (std.ascii.eqlIgnoreCase(name, header_name)) {
            return value;
        }
    }

    return null;
}

test "authorizeRequest supports x-api-key and bearer header" {
    const raw_x_api_key =
        "POST /v1/chat/completions HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "X-Api-Key: secret\r\n\r\n";
    try std.testing.expect(authorizeRequest("secret", raw_x_api_key) == .allowed);

    const raw_bearer =
        "POST /v1/chat/completions HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Authorization: Bearer secret\r\n\r\n";
    try std.testing.expect(authorizeRequest("secret", raw_bearer) == .allowed);

    try std.testing.expect(authorizeRequest("secret", "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n") == .denied);
}

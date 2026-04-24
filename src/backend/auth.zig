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
    if (timingSafeEql(supplied_key, required_api_key)) return .allowed;
    return .denied;
}

/// Constant-time API key comparison using HMAC-SHA256 digests.
///
/// Deriving a fixed-length MAC for each candidate before comparison
/// eliminates both content timing leaks (early exit on first differing byte)
/// and length timing leaks (early exit when the two slices have different
/// lengths).  The context key is public and non-secret; only digest equality
/// matters for the correctness of the comparison.
fn timingSafeEql(a: []const u8, b: []const u8) bool {
    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    const ctx_key = "zig-coding-agent/auth-key-cmp";
    var mac_a: [Hmac.mac_length]u8 = undefined;
    var mac_b: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&mac_a, a, ctx_key);
    Hmac.create(&mac_b, b, ctx_key);
    return std.crypto.utils.timingSafeEql([Hmac.mac_length]u8, mac_a, mac_b);
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

test "timingSafeEql returns false for different-length keys" {
    try std.testing.expect(!timingSafeEql("short", "longer-key"));
}

test "timingSafeEql returns false for same-length keys that differ" {
    try std.testing.expect(!timingSafeEql("key-aaaa", "key-bbbb"));
}

test "timingSafeEql returns true for identical keys" {
    try std.testing.expect(timingSafeEql("secret-api-key", "secret-api-key"));
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

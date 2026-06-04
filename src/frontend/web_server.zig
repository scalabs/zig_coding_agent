//! Lightweight HTTP server that serves the web UI and proxies
//! API requests to the backend on port 8081.
const std = @import("std");

const WEB_HOST = "127.0.0.1";
const WEB_PORT: u16 = 8080;
const BACKEND_HOST = "127.0.0.1";
const BACKEND_PORT: u16 = 8081;

const index_html = @embedFile("static/index.html");

const ParsedLine = struct {
    method: []const u8,
    path: []const u8,
};

pub fn run(allocator: std.mem.Allocator) !void {
    const address = try std.net.Address.parseIp(WEB_HOST, WEB_PORT);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.debug.print("\n========================================\n", .{});
    std.debug.print("  Zig AI Agent  —  Web UI\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("  Browser:  http://{s}:{d}\n", .{ WEB_HOST, WEB_PORT });
    std.debug.print("  Backend:  http://{s}:{d}\n", .{ BACKEND_HOST, BACKEND_PORT });
    std.debug.print("========================================\n\n", .{});

    while (true) {
        const conn = server.accept() catch |err| {
            std.debug.print("Accept error: {s}\n", .{@errorName(err)});
            continue;
        };
        handleConnection(allocator, conn.stream) catch |err| {
            std.debug.print("Request error: {s}\n", .{@errorName(err)});
        };
    }
}

fn handleConnection(allocator: std.mem.Allocator, stream: std.net.Stream) !void {
    defer stream.close();

    const raw = try readRequest(allocator, stream);
    defer allocator.free(raw);

    const line = parseRequestLine(raw) orelse {
        try sendError(allocator, stream, 400, "Bad Request");
        return;
    };

    // CORS preflight
    if (std.mem.eql(u8, line.method, "OPTIONS")) {
        try sendCorsOk(stream);
        return;
    }

    // GET / → serve UI
    if (std.mem.eql(u8, line.method, "GET") and std.mem.eql(u8, line.path, "/")) {
        try sendResponse(allocator, stream, 200, "text/html; charset=utf-8", index_html);
        return;
    }

    // GET /health → proxy
    if (std.mem.eql(u8, line.method, "GET") and std.mem.eql(u8, line.path, "/health")) {
        const body = proxyGet(allocator, "/health") catch |err| {
            return sendGatewayError(allocator, stream, err);
        };
        defer allocator.free(body);
        try sendResponse(allocator, stream, 200, "application/json", body);
        return;
    }

    // GET /diagnostics/providers → proxy
    if (std.mem.eql(u8, line.method, "GET") and
        std.mem.eql(u8, line.path, "/diagnostics/providers"))
    {
        const body = proxyGet(allocator, "/diagnostics/providers") catch |err| {
            return sendGatewayError(allocator, stream, err);
        };
        defer allocator.free(body);
        try sendResponse(allocator, stream, 200, "application/json", body);
        return;
    }

    // POST /v1/chat/completions → proxy
    if (std.mem.eql(u8, line.method, "POST") and
        std.mem.eql(u8, line.path, "/v1/chat/completions"))
    {
        const req_body = extractBody(raw);
        const resp_body = proxyPost(allocator, "/v1/chat/completions", req_body) catch |err| {
            return sendGatewayError(allocator, stream, err);
        };
        defer allocator.free(resp_body);
        try sendResponse(allocator, stream, 200, "application/json", resp_body);
        return;
    }

    try sendError(allocator, stream, 404, "Not Found");
}

// ── HTTP reading ────────────────────────────────────────────────

fn readRequest(allocator: std.mem.Allocator, stream: std.net.Stream) ![]u8 {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);

    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = try stream.read(&tmp);
        if (n == 0) break;
        try buf.appendSlice(allocator, tmp[0..n]);

        if (std.mem.indexOf(u8, buf.items, "\r\n\r\n")) |header_end| {
            const body_start = header_end + 4;
            if (extractContentLength(buf.items)) |cl| {
                if (buf.items.len >= body_start + cl) break;
            } else {
                break;
            }
        }
    }

    return try buf.toOwnedSlice(allocator);
}

fn parseRequestLine(request: []const u8) ?ParsedLine {
    const end = std.mem.indexOf(u8, request, "\r\n") orelse return null;
    var it = std.mem.splitScalar(u8, request[0..end], ' ');
    const method = it.next() orelse return null;
    const path   = it.next() orelse return null;
    return .{ .method = method, .path = path };
}

fn extractContentLength(headers: []const u8) ?usize {
    const header_end = std.mem.indexOf(u8, headers, "\r\n\r\n") orelse headers.len;
    const key = "Content-Length: ";
    const start = std.mem.indexOf(u8, headers[0..header_end], key) orelse return null;
    const rest = headers[start + key.len ..];
    const end = std.mem.indexOf(u8, rest, "\r\n") orelse rest.len;
    return std.fmt.parseInt(usize, rest[0..end], 10) catch null;
}

fn extractBody(request: []const u8) []const u8 {
    const idx = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return "";
    return request[idx + 4 ..];
}

// ── Proxy ───────────────────────────────────────────────────────

fn proxyGet(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const address = try std.net.Address.parseIp(BACKEND_HOST, BACKEND_PORT);
    const stream  = try std.net.tcpConnectToAddress(address);
    defer stream.close();

    const req = try std.fmt.allocPrint(allocator,
        "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n",
        .{ path, BACKEND_HOST, BACKEND_PORT });
    defer allocator.free(req);

    try stream.writeAll(req);
    return readResponseBody(allocator, stream);
}

fn proxyPost(allocator: std.mem.Allocator, path: []const u8, body: []const u8) ![]u8 {
    const address = try std.net.Address.parseIp(BACKEND_HOST, BACKEND_PORT);
    const stream  = try std.net.tcpConnectToAddress(address);
    defer stream.close();

    const req = try std.fmt.allocPrint(allocator,
        "POST {s} HTTP/1.1\r\nHost: {s}:{d}\r\n" ++
        "Content-Type: application/json\r\nContent-Length: {d}\r\n" ++
        "Connection: close\r\n\r\n{s}",
        .{ path, BACKEND_HOST, BACKEND_PORT, body.len, body });
    defer allocator.free(req);

    try stream.writeAll(req);
    return readResponseBody(allocator, stream);
}

fn readResponseBody(allocator: std.mem.Allocator, stream: std.net.Stream) ![]u8 {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);

    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = try stream.read(&tmp);
        if (n == 0) break;
        try buf.appendSlice(allocator, tmp[0..n]);
    }

    const full = try buf.toOwnedSlice(allocator);
    defer allocator.free(full);

    const idx = std.mem.indexOf(u8, full, "\r\n\r\n") orelse return allocator.dupe(u8, full);
    return allocator.dupe(u8, full[idx + 4 ..]);
}

// ── Responses ───────────────────────────────────────────────────

fn sendResponse(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    status: u16,
    content_type: []const u8,
    body: []const u8,
) !void {
    const status_text: []const u8 = switch (status) {
        200 => "OK", 204 => "No Content",
        400 => "Bad Request", 404 => "Not Found", 502 => "Bad Gateway",
        else => "OK",
    };
    const headers = try std.fmt.allocPrint(allocator,
        "HTTP/1.1 {d} {s}\r\n" ++
        "Content-Type: {s}\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Access-Control-Allow-Origin: *\r\n" ++
        "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" ++
        "Access-Control-Allow-Headers: Content-Type\r\n" ++
        "Connection: close\r\n\r\n",
        .{ status, status_text, content_type, body.len });
    defer allocator.free(headers);
    try stream.writeAll(headers);
    try stream.writeAll(body);
}

fn sendError(allocator: std.mem.Allocator, stream: std.net.Stream, code: u16, msg: []const u8) !void {
    const body = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{msg});
    defer allocator.free(body);
    try sendResponse(allocator, stream, code, "application/json", body);
}

fn sendGatewayError(allocator: std.mem.Allocator, stream: std.net.Stream, err: anyerror) void {
    const body = std.fmt.allocPrint(allocator,
        "{{\"error\":\"Backend unreachable: {s}\"}}", .{@errorName(err)}) catch return;
    defer allocator.free(body);
    sendResponse(allocator, stream, 502, "application/json", body) catch {};
}

fn sendCorsOk(stream: std.net.Stream) !void {
    try stream.writeAll(
        "HTTP/1.1 204 No Content\r\n" ++
        "Access-Control-Allow-Origin: *\r\n" ++
        "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" ++
        "Access-Control-Allow-Headers: Content-Type\r\n" ++
        "Connection: close\r\n\r\n");
}

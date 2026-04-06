const std = @import("std");
const config = @import("../config.zig");
const types = @import("../types.zig");
const request = @import("request.zig");
const response = @import("response.zig");
const router = @import("router.zig");
const backend = @import("../backend/api.zig");

/// Run the server and handle incoming connections
pub fn run(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
) !void {
    const address = try std.net.Address.parseIp(
        app_config.listen_host,
        app_config.listen_port,
    );

    var server = try address.listen(.{});
    defer server.deinit();

    logInfo(
        "Server running at http://{s}:{d}",
        .{ app_config.listen_host, app_config.listen_port },
    );
    logInfo("Default provider: {s}", .{app_config.default_provider});
    logInfo("Available providers: ollama (aliases: qwen, ollama_qwen)", .{});
    if (app_config.debug_logging) {
        logInfo("Debug logging enabled", .{});
    }

    while (true) {
        var connection = try server.accept();
        defer connection.stream.close();

        handleConnection(allocator, app_config, connection) catch |err| {
            logError("Request handling error: {}", .{err});
        };
    }
}

/// Handle a single client connection
fn handleConnection(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    connection: std.net.Server.Connection,
) !void {
    const request_raw = request.readHttpRequest(allocator, connection) catch |err| switch (err) {
        error.RequestTooLarge => {
            try response.sendApiError(connection, allocator, backend.errors.payloadTooLargeError());
            return;
        },
        error.HeadersTooLarge => {
            try response.sendApiError(connection, allocator, backend.errors.httpError(
                "HTTP headers are too large",
                "headers_too_large",
            ));
            return;
        },
        error.InvalidHttpRequest => {
            try response.sendApiError(connection, allocator, backend.errors.httpError(
                "Malformed HTTP request",
                "invalid_http_request",
            ));
            return;
        },
        error.MissingContentLength => {
            try response.sendApiError(connection, allocator, backend.errors.httpError(
                "Missing Content-Length header",
                "missing_content_length",
            ));
            return;
        },
        error.InvalidContentLength => {
            try response.sendApiError(connection, allocator, backend.errors.httpError(
                "Invalid Content-Length header",
                "invalid_content_length",
            ));
            return;
        },
        error.IncompleteRequestBody => {
            try response.sendApiError(connection, allocator, backend.errors.httpError(
                "Incomplete request body",
                "incomplete_body",
            ));
            return;
        },
        else => return err,
    };
    defer allocator.free(request_raw);

    if (request_raw.len == 0) return;

    debugLog(
        app_config,
        "request bytes={d} line={s}",
        .{ request_raw.len, request.firstRequestLine(request_raw) },
    );

    const is_chat_route = router.matchChatCompletionsRoute(request_raw) catch {
        try response.sendApiError(connection, allocator, backend.errors.httpError(
            "Malformed HTTP request",
            "invalid_http_request",
        ));
        return;
    };

    if (!is_chat_route) {
        try response.sendApiError(connection, allocator, backend.errors.notFoundError());
        return;
    }

    const body = request.findBody(request_raw) orelse {
        try response.sendApiError(connection, allocator, backend.errors.httpError(
            "Missing request body",
            "missing_body",
        ));
        return;
    };

    debugLog(app_config, "request body_len={d}", .{body.len});

    const parse_result = try backend.parseChatRequest(allocator, body);
    const parsed_req = switch (parse_result) {
        .ok => |parsed_request| parsed_request,
        .err => |api_error| {
            try response.sendApiError(connection, allocator, api_error);
            return;
        },
    };
    defer parsed_req.deinit(allocator);

    debugLog(
        app_config,
        "request provider={s} model={s} prompt_len={d} messages={d}",
        .{
            parsed_req.provider orelse app_config.default_provider,
            parsed_req.model orelse "(default)",
            parsed_req.prompt.len,
            parsed_req.messages.len,
        },
    );

    const result = backend.callProvider(allocator, app_config, parsed_req) catch |err| {
        logError("Provider request error: {}", .{err});
        try response.sendApiError(connection, allocator, backend.errors.providerError(
            "Local Ollama request failed",
            "provider_request_failed",
        ));
        return;
    };
    defer result.deinit(allocator);

    if (!result.success) {
        debugLog(
            app_config,
            "provider error model={s} message_len={d}",
            .{ result.model, result.output.len },
        );
        try response.sendApiError(connection, allocator, backend.errors.providerError(
            result.output,
            "provider_error",
        ));
        return;
    }

    debugLog(
        app_config,
        "response model={s} finish_reason={s} usage_total={d}",
        .{ result.model, result.finish_reason, result.usage.total_tokens },
    );
    try response.sendChatCompletion(connection, allocator, result);
}

fn debugLog(
    app_config: *const config.Config,
    comptime format: []const u8,
    args: anytype,
) void {
    if (!app_config.debug_logging) return;
    logDebug(format, args);
}

fn logDebug(comptime format: []const u8, args: anytype) void {
    std.debug.print("[debug] " ++ format ++ "\n", args);
}

fn logInfo(comptime format: []const u8, args: anytype) void {
    std.debug.print("[info] " ++ format ++ "\n", args);
}

fn logError(comptime format: []const u8, args: anytype) void {
    std.debug.print("[error] " ++ format ++ "\n", args);
}

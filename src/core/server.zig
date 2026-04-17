//! TCP server loop and request lifecycle orchestration.
const std = @import("std");
const config = @import("../config.zig");
const types = @import("../types.zig");
const request = @import("request.zig");
const response = @import("response.zig");
const router = @import("router.zig");
const backend = @import("../backend/api.zig");
const auth = @import("../backend/auth.zig");
const tooling = @import("../backend/tools.zig");
const session = @import("../backend/session.zig");

const ServerState = struct {
    total_requests: u64 = 0,
    successful_requests: u64 = 0,
    failed_requests: u64 = 0,
    active_connections: u64 = 0,
    connected_clients: std.ArrayList([]u8),

    fn init() ServerState {
        return .{ .connected_clients = .{} };
    }

    fn deinit(self: *ServerState, allocator: std.mem.Allocator) void {
        for (self.connected_clients.items) |client| {
            allocator.free(client);
        }
        self.connected_clients.deinit(allocator);
    }

    fn noteClient(self: *ServerState, allocator: std.mem.Allocator, label: []const u8) !void {
        for (self.connected_clients.items) |existing| {
            if (std.mem.eql(u8, existing, label)) return;
        }

        try self.connected_clients.append(allocator, try allocator.dupe(u8, label));
    }
};

/// Starts the TCP listener and serves requests indefinitely.
///
/// Args:
/// - allocator: allocator used by request parsing and response serialization.
/// - app_config: immutable runtime configuration for listen address and defaults.
///
/// Errors:
/// - propagates listener setup and accept-loop errors.
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
    logInfo(
        "Ollama speed settings: think={} num_predict={d} temperature={d:.2} repeat_penalty={d:.2}",
        .{
            app_config.ollama_think,
            app_config.ollama_num_predict,
            app_config.ollama_temperature,
            app_config.ollama_repeat_penalty,
        },
    );
    logInfo(
        "Timeouts: request_timeout_ms={d} provider_timeout_ms={d}",
        .{ app_config.request_timeout_ms, app_config.provider_timeout_ms },
    );

    const default_provider = types.normalizeProviderName(app_config.default_provider) orelse app_config.default_provider;
    if (std.mem.eql(u8, default_provider, "ollama_qwen")) {
        const provider_status = backend.buildProviderStatusJson(allocator, app_config) catch |err| blk: {
            logError("Provider status detection failed: {s}", .{@errorName(err)});
            break :blk null;
        };
        if (provider_status) |status| {
            defer allocator.free(status);
            logInfo("Provider status: {s}", .{status});
        }
    }

    if (app_config.debug_logging) {
        logInfo("Debug logging enabled", .{});
    }

    var server_state = ServerState.init();
    defer server_state.deinit(allocator);

    var tool_registry = tooling.ToolRegistry.init(allocator);
    defer tool_registry.deinit(allocator);
    try tool_registry.register(allocator, "echo");
    try tool_registry.register(allocator, "utc");

    while (true) {
        var connection = try server.accept();
        defer connection.stream.close();

        server_state.active_connections += 1;
        defer server_state.active_connections -= 1;

        // Client tracking is intentionally disabled in the hot path on Windows
        // until socket stability issues are fully resolved.

        handleConnection(allocator, app_config, &connection, &server_state, &tool_registry) catch |err| {
            logError("Request handling error: {s}", .{@errorName(err)});
            server_state.failed_requests += 1;
        };
    }
}

fn handleConnection(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    connection: *std.net.Server.Connection,
    server_state: *ServerState,
    tool_registry: *tooling.ToolRegistry,
) !void {
    // Translate transport-level parsing failures into OpenAI-style API errors.
    const request_raw = request.readHttpRequest(allocator, connection, app_config.request_timeout_ms) catch |err| switch (err) {
        error.ClientDisconnected => {
            debugLog(app_config, "client disconnected before full request", .{});
            return;
        },
        error.RequestTimedOut => {
            sendApiErrorSafe(connection.*, allocator, backend.errors.requestTimeoutError(), app_config);
            return;
        },
        error.RequestTooLarge => {
            sendApiErrorSafe(connection.*, allocator, backend.errors.payloadTooLargeError(), app_config);
            return;
        },
        error.HeadersTooLarge => {
            sendApiErrorSafe(connection.*, allocator, backend.errors.httpError(
                "HTTP headers are too large",
                "headers_too_large",
            ), app_config);
            return;
        },
        error.InvalidHttpRequest => {
            sendApiErrorSafe(connection.*, allocator, backend.errors.httpError(
                "Malformed HTTP request",
                "invalid_http_request",
            ), app_config);
            return;
        },
        error.MissingContentLength => {
            sendApiErrorSafe(connection.*, allocator, backend.errors.httpError(
                "Missing Content-Length header",
                "missing_content_length",
            ), app_config);
            return;
        },
        error.InvalidContentLength => {
            sendApiErrorSafe(connection.*, allocator, backend.errors.httpError(
                "Invalid Content-Length header",
                "invalid_content_length",
            ), app_config);
            return;
        },
        error.IncompleteRequestBody => {
            sendApiErrorSafe(connection.*, allocator, backend.errors.httpError(
                "Incomplete request body",
                "incomplete_body",
            ), app_config);
            return;
        },
        else => {
            debugLog(app_config, "unhandled socket read error: {s}", .{@errorName(err)});
            return;
        },
    };
    defer allocator.free(request_raw);

    if (request_raw.len == 0) return;
    server_state.total_requests += 1;

    debugLog(
        app_config,
        "request bytes={d} line={s}",
        .{ request_raw.len, request.firstRequestLine(request_raw) },
    );

    const route = router.parseRoute(request_raw) catch {
        sendApiErrorSafe(connection.*, allocator, backend.errors.httpError(
            "Malformed HTTP request",
            "invalid_http_request",
        ), app_config);
        server_state.failed_requests += 1;
        return;
    };

    if (route == null) {
        sendApiErrorSafe(connection.*, allocator, backend.errors.notFoundError(), app_config);
        server_state.failed_requests += 1;
        return;
    }

    if (requiresAuth(route.?) and auth.authorizeRequest(app_config.auth_api_key, request_raw) == .denied) {
        sendJsonSafe(connection.*, 401, "{\"error\":{\"message\":\"Unauthorized\",\"type\":\"auth_error\",\"param\":null,\"code\":\"unauthorized\"}}", app_config);
        server_state.failed_requests += 1;
        return;
    }

    switch (route.?) {
        .health => {
            const health_json = try std.fmt.allocPrint(
                allocator,
                "{{\"status\":\"ok\",\"instance_id\":\"{s}\"}}",
                .{app_config.instance_id},
            );
            defer allocator.free(health_json);
            sendJsonSafe(connection.*, 200, health_json, app_config);
            server_state.successful_requests += 1;
            return;
        },
        .metrics => {
            const metrics_json = try std.fmt.allocPrint(
                allocator,
                "{{\"instance_id\":\"{s}\",\"total_requests\":{d},\"successful_requests\":{d},\"failed_requests\":{d},\"active_connections\":{d}}}",
                .{
                    app_config.instance_id,
                    server_state.total_requests,
                    server_state.successful_requests,
                    server_state.failed_requests,
                    server_state.active_connections,
                },
            );
            defer allocator.free(metrics_json);
            sendJsonSafe(connection.*, 200, metrics_json, app_config);
            server_state.successful_requests += 1;
            return;
        },
        .diagnostics_clients => {
            var clients_json = std.ArrayList(u8){};
            defer clients_json.deinit(allocator);
            try clients_json.append(allocator, '[');
            for (server_state.connected_clients.items, 0..) |client, idx| {
                if (idx > 0) try clients_json.append(allocator, ',');
                const escaped = try response.escapeJsonStringAlloc(allocator, client);
                defer allocator.free(escaped);
                try clients_json.writer(allocator).print("\"{s}\"", .{escaped});
            }
            try clients_json.append(allocator, ']');

            const payload = try std.fmt.allocPrint(
                allocator,
                "{{\"instance_id\":\"{s}\",\"active_connections\":{d},\"known_clients\":{s}}}",
                .{ app_config.instance_id, server_state.active_connections, clients_json.items },
            );
            defer allocator.free(payload);
            sendJsonSafe(connection.*, 200, payload, app_config);
            server_state.successful_requests += 1;
            return;
        },
        .diagnostics_requests => {
            const payload = try std.fmt.allocPrint(
                allocator,
                "{{\"instance_id\":\"{s}\",\"total_requests\":{d},\"successful_requests\":{d},\"failed_requests\":{d}}}",
                .{
                    app_config.instance_id,
                    server_state.total_requests,
                    server_state.successful_requests,
                    server_state.failed_requests,
                },
            );
            defer allocator.free(payload);
            sendJsonSafe(connection.*, 200, payload, app_config);
            server_state.successful_requests += 1;
            return;
        },
        .diagnostics_providers => {
            const provider_status = try backend.buildProviderStatusJson(allocator, app_config);
            defer allocator.free(provider_status);

            const payload = try std.fmt.allocPrint(
                allocator,
                "{{\"instance_id\":\"{s}\",\"providers\":{s}}}",
                .{ app_config.instance_id, provider_status },
            );
            defer allocator.free(payload);

            sendJsonSafe(connection.*, 200, payload, app_config);
            server_state.successful_requests += 1;
            return;
        },
        .chat_completions => {},
    }

    const body = request.findBody(request_raw) orelse {
        sendApiErrorSafe(connection.*, allocator, backend.errors.httpError(
            "Missing request body",
            "missing_body",
        ), app_config);
        server_state.failed_requests += 1;
        return;
    };

    debugLog(app_config, "request body_len={d}", .{body.len});

    const parse_result = try backend.parseChatRequest(allocator, body);
    const parsed_req = switch (parse_result) {
        .ok => |parsed_request| parsed_request,
        .err => |api_error| {
            sendApiErrorSafe(connection.*, allocator, api_error, app_config);
            server_state.failed_requests += 1;
            return;
        },
    };
    defer parsed_req.deinit(allocator);

    if (!tooling.validateRequestedTools(tool_registry, parsed_req.tools)) {
        sendApiErrorSafe(connection.*, allocator, backend.errors.validationError(
            "One or more requested tools are not registered",
            "tools",
            "unknown_tool",
        ), app_config);
        server_state.failed_requests += 1;
        return;
    }

    if (parsed_req.max_context_tokens) |max_tokens| {
        const estimated = session.estimateTokenCount(parsed_req.messages);
        if (session.shouldCompressContext(estimated, max_tokens)) {
            debugLog(
                app_config,
                "context compression suggested estimated_tokens={d} max_context_tokens={d}",
                .{ estimated, max_tokens },
            );
        }
    }

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

    if (parsed_req.stream) {
        const requested_provider = parsed_req.provider orelse app_config.default_provider;
        const normalized_provider = types.normalizeProviderName(requested_provider) orelse requested_provider;

        if (!std.mem.eql(u8, normalized_provider, "ollama_qwen")) {
            sendApiErrorSafe(connection.*, allocator, backend.errors.validationError(
                "stream=true is currently supported only for ollama",
                "stream",
                "unsupported_stream_provider",
            ), app_config);
            server_state.failed_requests += 1;
            return;
        }

        const ollama_qwen = @import("../providers/ollama_qwen.zig");
        const stream_result = ollama_qwen.streamQwenToSse(connection.*, allocator, app_config, parsed_req) catch |err| {
            logError("Provider stream error: {s}", .{@errorName(err)});
            server_state.failed_requests += 1;
            return;
        };

        switch (stream_result) {
            .streamed => {
                server_state.successful_requests += 1;
                return;
            },
            .failed => |provider_error_response| {
                defer provider_error_response.deinit(allocator);
                sendApiErrorSafe(connection.*, allocator, backend.errors.providerError(
                    provider_error_response.output,
                    "provider_error",
                ), app_config);
                server_state.failed_requests += 1;
                return;
            },
        }
    }

    if (try tooling.tryExecuteDebugTool(allocator, parsed_req)) |tool_result| {
        defer tool_result.deinit(allocator);
        debugLog(
            app_config,
            "debug tool executed tool_choice={s}",
            .{parsed_req.tool_choice orelse "(none)"},
        );
        sendChatCompletionSafe(connection.*, allocator, tool_result, app_config);
        server_state.successful_requests += 1;
        return;
    }

    const requested_provider = parsed_req.provider orelse app_config.default_provider;
    const normalized_provider = types.normalizeProviderName(requested_provider) orelse requested_provider;

    const provider_started_ms = std.time.milliTimestamp();
    const result = backend.callProvider(allocator, app_config, parsed_req) catch |err| {
        logError("Provider request error: {}", .{err});
        sendApiErrorSafe(
            connection.*,
            allocator,
            backend.errors.providerTransportError(@errorName(err)),
            app_config,
        );
        server_state.failed_requests += 1;
        return;
    };
    defer result.deinit(allocator);

    const provider_elapsed_ms: u64 = @intCast(@max(std.time.milliTimestamp() - provider_started_ms, 0));
    if (provider_elapsed_ms > app_config.provider_timeout_ms) {
        sendApiErrorSafe(
            connection.*,
            allocator,
            backend.errors.providerTransportError("ProviderTimeout"),
            app_config,
        );
        server_state.failed_requests += 1;
        return;
    }

    if (!result.success) {
        debugLog(
            app_config,
            "provider error model={s} message_len={d}",
            .{ result.model, result.output.len },
        );
        sendApiErrorSafe(
            connection.*,
            allocator,
            backend.errors.providerFailureFromDetail(normalized_provider, result.output),
            app_config,
        );
        server_state.failed_requests += 1;
        return;
    }

    debugLog(
        app_config,
        "response model={s} finish_reason={s} usage_total={d}",
        .{ result.model, result.finish_reason, result.usage.total_tokens },
    );
    sendChatCompletionSafe(connection.*, allocator, result, app_config);
    server_state.successful_requests += 1;
}

fn sendApiErrorSafe(
    connection: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    api_error: backend.errors.ApiError,
    app_config: *const config.Config,
) void {
    response.sendApiError(connection, allocator, api_error) catch |err| {
        swallowSocketWriteError(app_config, err);
    };
}

fn sendJsonSafe(
    connection: std.net.Server.Connection,
    status_code: u16,
    body: []const u8,
    app_config: *const config.Config,
) void {
    response.sendJsonText(connection, status_code, body) catch |err| {
        swallowSocketWriteError(app_config, err);
    };
}

fn sendChatCompletionSafe(
    connection: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    result: types.Response,
    app_config: *const config.Config,
) void {
    response.sendChatCompletion(connection, allocator, result) catch |err| {
        swallowSocketWriteError(app_config, err);
    };
}

fn swallowSocketWriteError(
    app_config: *const config.Config,
    err: anyerror,
) void {
    switch (err) {
        error.Unexpected,
        error.ConnectionResetByPeer,
        error.BrokenPipe,
        error.OperationAborted,
        error.NotOpenForWriting,
        => debugLog(app_config, "socket write aborted: {s}", .{@errorName(err)}),
        else => logError("response write error: {s}", .{@errorName(err)}),
    }
}

fn requiresAuth(route: router.Route) bool {
    return switch (route) {
        .health => false,
        .diagnostics_providers => false,
        else => true,
    };
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

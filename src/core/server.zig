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

    var server_state = ServerState.init();
    defer server_state.deinit(allocator);

    var tool_registry = tooling.ToolRegistry.init(allocator);
    defer tool_registry.deinit(allocator);
    try tool_registry.register(allocator, "echo");
    try tool_registry.register(allocator, "http_get");

    while (true) {
        var connection = try server.accept();
        defer connection.stream.close();

        server_state.active_connections += 1;
        defer server_state.active_connections -= 1;

        const client_label = std.fmt.allocPrint(allocator, "{any}", .{connection.address}) catch "unknown";
        if (!std.mem.eql(u8, client_label, "unknown")) {
            defer allocator.free(client_label);
            server_state.noteClient(allocator, client_label) catch {};
        }

        handleConnection(allocator, app_config, connection, &server_state, &tool_registry) catch |err| {
            logError("Request handling error: {}", .{err});
            server_state.failed_requests += 1;
        };
    }
}

/// Handle a single client connection
fn handleConnection(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    connection: std.net.Server.Connection,
    server_state: *ServerState,
    tool_registry: *tooling.ToolRegistry,
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
    server_state.total_requests += 1;

    debugLog(
        app_config,
        "request bytes={d} line={s}",
        .{ request_raw.len, request.firstRequestLine(request_raw) },
    );

    const route = router.parseRoute(request_raw) catch {
        try response.sendApiError(connection, allocator, backend.errors.httpError(
            "Malformed HTTP request",
            "invalid_http_request",
        ));
        server_state.failed_requests += 1;
        return;
    };

    if (route == null) {
        try response.sendApiError(connection, allocator, backend.errors.notFoundError());
        server_state.failed_requests += 1;
        return;
    }

    if (requiresAuth(route.?) and auth.authorizeRequest(app_config.auth_api_key, request_raw) == .denied) {
        try response.sendJsonText(connection, 401, "{\"error\":{\"message\":\"Unauthorized\",\"type\":\"auth_error\",\"param\":null,\"code\":\"unauthorized\"}}");
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
            try response.sendJsonText(connection, 200, health_json);
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
            try response.sendJsonText(connection, 200, metrics_json);
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
            try response.sendJsonText(connection, 200, payload);
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
            try response.sendJsonText(connection, 200, payload);
            server_state.successful_requests += 1;
            return;
        },
        .chat_completions => {},
    }

    const body = request.findBody(request_raw) orelse {
        try response.sendApiError(connection, allocator, backend.errors.httpError(
            "Missing request body",
            "missing_body",
        ));
        server_state.failed_requests += 1;
        return;
    };

    debugLog(app_config, "request body_len={d}", .{body.len});

    const parse_result = try backend.parseChatRequest(allocator, body);
    const parsed_req = switch (parse_result) {
        .ok => |parsed_request| parsed_request,
        .err => |api_error| {
            try response.sendApiError(connection, allocator, api_error);
            server_state.failed_requests += 1;
            return;
        },
    };
    defer parsed_req.deinit(allocator);

    if (!tooling.validateRequestedTools(tool_registry, parsed_req.tools)) {
        try response.sendApiError(connection, allocator, backend.errors.validationError(
            "One or more requested tools are not registered",
            "tools",
            "unknown_tool",
        ));
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

    const result = backend.callProvider(allocator, app_config, parsed_req) catch |err| {
        logError("Provider request error: {}", .{err});
        try response.sendApiError(connection, allocator, backend.errors.providerError(
            "Provider request failed",
            "provider_request_failed",
        ));
        server_state.failed_requests += 1;
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
        server_state.failed_requests += 1;
        return;
    }

    debugLog(
        app_config,
        "response model={s} finish_reason={s} usage_total={d}",
        .{ result.model, result.finish_reason, result.usage.total_tokens },
    );
    try response.sendChatCompletion(connection, allocator, result);
    server_state.successful_requests += 1;
}

fn requiresAuth(route: router.Route) bool {
    return switch (route) {
        .health => false,
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

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
    mutex: std.Thread.Mutex = .{},
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
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.connected_clients.items) |existing| {
            if (std.mem.eql(u8, existing, label)) return;
        }

        try self.connected_clients.append(allocator, try allocator.dupe(u8, label));
    }

    fn noteRequestStarted(self: *ServerState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.total_requests += 1;
    }

    fn noteRequestSucceeded(self: *ServerState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.successful_requests += 1;
    }

    fn noteRequestFailed(self: *ServerState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.failed_requests += 1;
    }

    fn noteConnectionOpened(self: *ServerState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.active_connections += 1;
    }

    fn noteConnectionClosed(self: *ServerState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.active_connections -= 1;
    }

    fn snapshot(self: *ServerState) Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .total_requests = self.total_requests,
            .successful_requests = self.successful_requests,
            .failed_requests = self.failed_requests,
            .active_connections = self.active_connections,
        };
    }

    fn knownClientsJsonAlloc(self: *ServerState, allocator: std.mem.Allocator) ![]u8 {
        var clients_json = std.ArrayList(u8){};
        errdefer clients_json.deinit(allocator);

        self.mutex.lock();
        defer self.mutex.unlock();

        try clients_json.append(allocator, '[');
        for (self.connected_clients.items, 0..) |client, idx| {
            if (idx > 0) try clients_json.append(allocator, ',');
            const escaped = try response.escapeJsonStringAlloc(allocator, client);
            defer allocator.free(escaped);
            try clients_json.writer(allocator).print("\"{s}\"", .{escaped});
        }
        try clients_json.append(allocator, ']');
        return try clients_json.toOwnedSlice(allocator);
    }
};

const Snapshot = struct {
    total_requests: u64,
    successful_requests: u64,
    failed_requests: u64,
    active_connections: u64,
};

const ConnectionGate = struct {
    mutex: std.Thread.Mutex = .{},
    active: usize = 0,
    max_active: usize,

    fn tryAcquire(self: *ConnectionGate) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.active >= self.max_active) return false;
        self.active += 1;
        return true;
    }

    fn release(self: *ConnectionGate) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.active -= 1;
    }
};

const SessionStoreGuard = struct {
    mutex: std.Thread.Mutex = .{},
};

const WorkerContext = struct {
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    server_state: *ServerState,
    tool_registry: *tooling.ToolRegistry,
    session_store: ?*session.SessionStore,
    session_store_guard: *SessionStoreGuard,
    gate: *ConnectionGate,
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
    logInfo(
        "Available providers: ollama (aliases: qwen, ollama_qwen), openai, openrouter, claude (alias: anthropic), bedrock, llama_cpp (alias: llama.cpp)",
        .{},
    );
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

    const provider_status = backend.buildProviderStatusJson(allocator, app_config) catch |err| blk: {
        logError("Provider status detection failed: {s}", .{@errorName(err)});
        break :blk null;
    };
    if (provider_status) |status| {
        defer allocator.free(status);
        logInfo("Provider status: {s}", .{status});
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
    try tool_registry.register(allocator, "cmd");
    try tool_registry.register(allocator, "bash");

    var file_session_store: ?session.FileSessionStore = null;
    var session_store: ?session.SessionStore = null;
    if (app_config.session_store_path.len > 0) {
        file_session_store = session.FileSessionStore.init(
            allocator,
            app_config.session_store_path,
            app_config.session_retention_messages,
        ) catch |err| blk: {
            logError("Session store initialization failed: {s}", .{@errorName(err)});
            break :blk null;
        };

        if (file_session_store) |*store_impl| {
            session_store = store_impl.asStore();
            logInfo(
                "Session persistence enabled path={s} retention_messages={d}",
                .{ app_config.session_store_path, app_config.session_retention_messages },
            );
        }
    }
    defer if (session_store) |*store| store.deinit(allocator);

    const active_session_store: ?*session.SessionStore = if (session_store) |*store| store else null;

    var gate = ConnectionGate{ .max_active = app_config.max_concurrent_connections };
    var session_store_guard = SessionStoreGuard{};
    const worker_context = WorkerContext{
        .allocator = allocator,
        .app_config = app_config,
        .server_state = &server_state,
        .tool_registry = &tool_registry,
        .session_store = active_session_store,
        .session_store_guard = &session_store_guard,
        .gate = &gate,
    };

    while (true) {
        const connection = try server.accept();
        if (!gate.tryAcquire()) {
            sendJsonSafe(
                connection,
                503,
                "{\"error\":{\"message\":\"Server is at connection capacity\",\"type\":\"server_error\",\"param\":null,\"code\":\"connection_capacity\"}}",
                app_config,
            );
            connection.stream.close();
            continue;
        }

        var worker = try std.Thread.spawn(.{}, connectionWorkerMain, .{ worker_context, connection });
        worker.detach();
    }
}

fn connectionWorkerMain(context: WorkerContext, connection: std.net.Server.Connection) void {
    defer context.gate.release();
    var worker_connection = connection;
    defer worker_connection.stream.close();
    context.server_state.noteConnectionOpened();
    defer context.server_state.noteConnectionClosed();

    handleConnection(
        context.allocator,
        context.app_config,
        &worker_connection,
        context.server_state,
        context.tool_registry,
        context.session_store,
        context.session_store_guard,
    ) catch |err| {
        logError("Request handling error: {s}", .{@errorName(err)});
        context.server_state.noteRequestFailed();
    };
}

fn handleConnection(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    connection: *std.net.Server.Connection,
    server_state: *ServerState,
    tool_registry: *tooling.ToolRegistry,
    session_store: ?*session.SessionStore,
    session_store_guard: *SessionStoreGuard,
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
    server_state.noteRequestStarted();

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
        server_state.noteRequestFailed();
        return;
    };

    if (route == null) {
        sendApiErrorSafe(connection.*, allocator, backend.errors.notFoundError(), app_config);
        server_state.noteRequestFailed();
        return;
    }

    if (requiresAuth(route.?) and auth.authorizeRequest(app_config.auth_api_key, request_raw) == .denied) {
        sendJsonSafe(connection.*, 401, "{\"error\":{\"message\":\"Unauthorized\",\"type\":\"auth_error\",\"param\":null,\"code\":\"unauthorized\"}}", app_config);
        server_state.noteRequestFailed();
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
            server_state.noteRequestSucceeded();
            return;
        },
        .metrics => {
            const snapshot = server_state.snapshot();
            const metrics_json = try std.fmt.allocPrint(
                allocator,
                "{{\"instance_id\":\"{s}\",\"total_requests\":{d},\"successful_requests\":{d},\"failed_requests\":{d},\"active_connections\":{d}}}",
                .{
                    app_config.instance_id,
                    snapshot.total_requests,
                    snapshot.successful_requests,
                    snapshot.failed_requests,
                    snapshot.active_connections,
                },
            );
            defer allocator.free(metrics_json);
            sendJsonSafe(connection.*, 200, metrics_json, app_config);
            server_state.noteRequestSucceeded();
            return;
        },
        .diagnostics_clients => {
            const snapshot = server_state.snapshot();
            const clients_json = try server_state.knownClientsJsonAlloc(allocator);
            defer allocator.free(clients_json);

            const payload = try std.fmt.allocPrint(
                allocator,
                "{{\"instance_id\":\"{s}\",\"active_connections\":{d},\"known_clients\":{s}}}",
                .{ app_config.instance_id, snapshot.active_connections, clients_json },
            );
            defer allocator.free(payload);
            sendJsonSafe(connection.*, 200, payload, app_config);
            server_state.noteRequestSucceeded();
            return;
        },
        .diagnostics_requests => {
            const snapshot = server_state.snapshot();
            const payload = try std.fmt.allocPrint(
                allocator,
                "{{\"instance_id\":\"{s}\",\"total_requests\":{d},\"successful_requests\":{d},\"failed_requests\":{d}}}",
                .{
                    app_config.instance_id,
                    snapshot.total_requests,
                    snapshot.successful_requests,
                    snapshot.failed_requests,
                },
            );
            defer allocator.free(payload);
            sendJsonSafe(connection.*, 200, payload, app_config);
            server_state.noteRequestSucceeded();
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
            server_state.noteRequestSucceeded();
            return;
        },
        .chat_completions => {},
    }

    const body = request.findBody(request_raw) orelse {
        sendApiErrorSafe(connection.*, allocator, backend.errors.httpError(
            "Missing request body",
            "missing_body",
        ), app_config);
        server_state.noteRequestFailed();
        return;
    };

    debugLog(app_config, "request body_len={d}", .{body.len});

    const parse_result = try backend.parseChatRequest(allocator, body);
    const parsed_req = switch (parse_result) {
        .ok => |parsed_request| parsed_request,
        .err => |api_error| {
            sendApiErrorSafe(connection.*, allocator, api_error, app_config);
            server_state.noteRequestFailed();
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
        server_state.noteRequestFailed();
        return;
    }

    var loaded_session: ?session.SessionState = null;
    defer if (loaded_session) |state| state.deinit(allocator);

    var request_messages = try session.cloneMessagesAlloc(allocator, parsed_req.messages);
    defer {
        for (request_messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(request_messages);
    }

    var request_prompt = try allocator.dupe(u8, parsed_req.prompt);
    defer allocator.free(request_prompt);

    if (session_store) |store| {
        if (parsed_req.session_id) |session_id| {
            session_store_guard.mutex.lock();
            loaded_session = store.load(allocator, session_id, parsed_req.tenant_id) catch |err| blk: {
                logError("Session load failed for '{s}': {s}", .{ session_id, @errorName(err) });
                break :blk null;
            };
            session_store_guard.mutex.unlock();

            if (loaded_session) |state| {
                if (state.messages.len > 0) {
                    const merged_messages = try session.mergeMessagesAlloc(
                        allocator,
                        state.messages,
                        parsed_req.messages,
                    );

                    for (request_messages) |message| {
                        message.deinit(allocator);
                    }
                    allocator.free(request_messages);
                    request_messages = merged_messages;

                    allocator.free(request_prompt);
                    request_prompt = try extractLastUserPromptAlloc(allocator, request_messages);
                }
            }
        }
    }

    if (parsed_req.max_context_tokens) |max_tokens| {
        const estimated = session.estimateTokenCount(request_messages);
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
            request_prompt.len,
            request_messages.len,
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
            server_state.noteRequestFailed();
            return;
        }

        var stream_request = try cloneRequestWithMessagesAlloc(
            allocator,
            parsed_req,
            request_prompt,
            request_messages,
        );
        defer stream_request.deinit(allocator);

        const stream_auto_tool_summary = try tooling.maybeExecutePromptToolsAlloc(allocator, stream_request, app_config);
        defer if (stream_auto_tool_summary) |summary| allocator.free(summary);

        if (stream_auto_tool_summary) |summary| {
            const augmented_messages = try appendSystemMessageAlloc(allocator, stream_request.messages, summary);
            for (stream_request.messages) |message| {
                message.deinit(allocator);
            }
            allocator.free(stream_request.messages);
            stream_request.messages = augmented_messages;
        }

        const stream_loop_enabled = stream_request.loop_mode != null or stream_request.loop_max_turns != null;
        if (stream_loop_enabled) {
            streamLoopRequestToSse(
                connection.*,
                allocator,
                app_config,
                stream_request,
                app_config.loop_stream_progress_enabled,
            ) catch |err| {
                logError("Provider stream loop error: {s}", .{@errorName(err)});
                server_state.noteRequestFailed();
                return;
            };

            server_state.noteRequestSucceeded();
            return;
        }

        const ollama_qwen = @import("../providers/ollama_qwen.zig");
        const stream_result = ollama_qwen.streamQwenToSse(connection.*, allocator, app_config, stream_request) catch |err| {
            logError("Provider stream error: {s}", .{@errorName(err)});
            server_state.noteRequestFailed();
            return;
        };

        switch (stream_result) {
            .streamed => {
                server_state.noteRequestSucceeded();
                return;
            },
            .failed => |provider_error_response| {
                defer provider_error_response.deinit(allocator);
                sendApiErrorSafe(connection.*, allocator, backend.errors.providerError(
                    provider_error_response.output,
                    "provider_error",
                ), app_config);
                server_state.noteRequestFailed();
                return;
            },
        }
    }

    if (try tooling.tryExecuteDebugTool(allocator, parsed_req, app_config)) |tool_result| {
        defer tool_result.deinit(allocator);
        debugLog(
            app_config,
            "debug tool executed tool_choice={s}",
            .{parsed_req.tool_choice orelse "(none)"},
        );
        sendChatCompletionSafe(connection.*, allocator, tool_result, app_config);
        server_state.noteRequestSucceeded();
        return;
    }

    const requested_provider = parsed_req.provider orelse app_config.default_provider;
    const normalized_provider = types.normalizeProviderName(requested_provider) orelse requested_provider;

    var provider_request = try cloneRequestWithMessagesAlloc(
        allocator,
        parsed_req,
        request_prompt,
        request_messages,
    );
    defer provider_request.deinit(allocator);

    const auto_tool_summary = try tooling.maybeExecutePromptToolsAlloc(allocator, provider_request, app_config);
    defer if (auto_tool_summary) |summary| allocator.free(summary);

    if (auto_tool_summary) |summary| {
        const augmented_messages = try appendSystemMessageAlloc(allocator, provider_request.messages, summary);

        for (provider_request.messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(provider_request.messages);
        provider_request.messages = augmented_messages;
    }

    var loop_messages_for_persistence: ?[]types.Message = null;
    defer if (loop_messages_for_persistence) |messages| {
        for (messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(messages);
    };

    var result: types.Response = undefined;
    var result_ready = false;
    defer if (result_ready) result.deinit(allocator);

    const loop_enabled = provider_request.loop_mode != null or provider_request.loop_max_turns != null;

    const provider_started_ms = std.time.milliTimestamp();
    if (loop_enabled) {
        const loop_execution = executeLoopRequestAlloc(allocator, app_config, provider_request) catch |err| {
            logError("Provider loop request error: {}", .{err});
            sendApiErrorSafe(
                connection.*,
                allocator,
                backend.errors.providerTransportError(@errorName(err)),
                app_config,
            );
            server_state.noteRequestFailed();
            return;
        };

        result = loop_execution.response;
        result_ready = true;
        loop_messages_for_persistence = loop_execution.messages;
    } else {
        result = backend.callProvider(allocator, app_config, provider_request) catch |err| {
            logError("Provider request error: {}", .{err});
            sendApiErrorSafe(
                connection.*,
                allocator,
                backend.errors.providerTransportError(@errorName(err)),
                app_config,
            );
            server_state.noteRequestFailed();
            return;
        };
        result_ready = true;
    }

    const provider_elapsed_ms: u64 = @intCast(@max(std.time.milliTimestamp() - provider_started_ms, 0));
    // Log a warning when the provider exceeded the configured timeout budget, but
    // do NOT discard the already-completed response.  A post-hoc check cannot
    // cancel an in-flight HTTP call; discarding a valid result would only confuse
    // the client.  Real request cancellation requires a concurrent timer and is
    // tracked as a future improvement.
    if (provider_elapsed_ms > app_config.provider_timeout_ms) {
        logError(
            "Provider response exceeded timeout budget elapsed_ms={d} timeout_ms={d}",
            .{ provider_elapsed_ms, app_config.provider_timeout_ms },
        );
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
        server_state.noteRequestFailed();
        return;
    }

    if (std.mem.trim(u8, result.output, " \t\r\n").len == 0) {
        if (auto_tool_summary) |summary| {
            allocator.free(result.output);
            result.output = try std.fmt.allocPrint(
                allocator,
                "Tool-assisted fallback response (model returned empty text):\n\n{s}",
                .{summary},
            );

            allocator.free(result.finish_reason);
            result.finish_reason = try allocator.dupe(u8, "tool_fallback");
        } else {
            sendApiErrorSafe(
                connection.*,
                allocator,
                backend.errors.providerError(
                    "Provider returned empty assistant content",
                    "empty_model_response",
                ),
                app_config,
            );
            server_state.noteRequestFailed();
            return;
        }
    }

    debugLog(
        app_config,
        "response model={s} finish_reason={s} usage_total={d}",
        .{ result.model, result.finish_reason, result.usage.total_tokens },
    );

    if (session_store) |store| {
        if (parsed_req.session_id) |session_id| {
            const loop_messages = loop_messages_for_persistence;
            const with_assistant = if (loop_messages) |messages| blk: {
                break :blk try session.cloneMessagesAlloc(allocator, messages);
            } else session.appendAssistantMessageAlloc(
                allocator,
                provider_request.messages,
                result.output,
            ) catch |err| blk: {
                logError("Session append failed for '{s}': {s}", .{ session_id, @errorName(err) });
                break :blk null;
            };

            if (with_assistant) |messages| {
                defer {
                    for (messages) |message| {
                        message.deinit(allocator);
                    }
                    allocator.free(messages);
                }

                var state = session.SessionState{
                    .session_id = try allocator.dupe(u8, session_id),
                    .tenant_id = if (parsed_req.tenant_id) |value| try allocator.dupe(u8, value) else null,
                    .summary = if (loaded_session) |loaded| try allocator.dupe(u8, loaded.summary) else try allocator.dupe(u8, ""),
                    .messages = try session.trimToRetentionAlloc(
                        allocator,
                        messages,
                        app_config.session_retention_messages,
                    ),
                    .message_count = 0,
                };
                state.message_count = state.messages.len;
                defer state.deinit(allocator);

                session_store_guard.mutex.lock();
                store.save(allocator, state) catch |err| {
                    logError("Session save failed for '{s}': {s}", .{ session_id, @errorName(err) });
                };
                session_store_guard.mutex.unlock();
            }
        }
    }

    sendChatCompletionSafe(connection.*, allocator, result, app_config);
    server_state.noteRequestSucceeded();
}

fn cloneRequestWithMessagesAlloc(
    allocator: std.mem.Allocator,
    parsed_req: types.Request,
    prompt: []const u8,
    messages: []const types.Message,
) !types.Request {
    const copied_messages = try session.cloneMessagesAlloc(allocator, messages);
    errdefer {
        for (copied_messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(copied_messages);
    }

    var copied_tools = try allocator.alloc(types.Tool, parsed_req.tools.len);
    var initialized_tools: usize = 0;
    errdefer {
        for (copied_tools[0..initialized_tools]) |tool| {
            tool.deinit(allocator);
        }
        allocator.free(copied_tools);
    }

    for (parsed_req.tools, 0..) |tool, idx| {
        copied_tools[idx] = .{
            .name = try allocator.dupe(u8, tool.name),
            .description = try allocator.dupe(u8, tool.description),
        };
        initialized_tools += 1;
    }

    return .{
        .prompt = try allocator.dupe(u8, prompt),
        .messages = copied_messages,
        .provider = if (parsed_req.provider) |provider| try allocator.dupe(u8, provider) else null,
        .model = if (parsed_req.model) |model| try allocator.dupe(u8, model) else null,
        .stream = parsed_req.stream,
        .think = parsed_req.think,
        .temperature = parsed_req.temperature,
        .repeat_penalty = parsed_req.repeat_penalty,
        .session_id = if (parsed_req.session_id) |session_id| try allocator.dupe(u8, session_id) else null,
        .tenant_id = if (parsed_req.tenant_id) |tenant_id| try allocator.dupe(u8, tenant_id) else null,
        .max_context_tokens = parsed_req.max_context_tokens,
        .tools = copied_tools,
        .tool_choice = if (parsed_req.tool_choice) |tool_choice| try allocator.dupe(u8, tool_choice) else null,
        .loop_mode = if (parsed_req.loop_mode) |loop_mode| try allocator.dupe(u8, loop_mode) else null,
        .loop_until = if (parsed_req.loop_until) |loop_until| try allocator.dupe(u8, loop_until) else null,
        .loop_max_turns = parsed_req.loop_max_turns,
    };
}

const LoopExecution = struct {
    response: types.Response,
    messages: []types.Message,
};

fn streamLoopRequestToSse(
    connection: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    base_request: types.Request,
    emit_progress: bool,
) !void {
    const loop_mode = base_request.loop_mode orelse "basic";
    const loop_until = base_request.loop_until orelse "DONE";
    const loop_max_turns = base_request.loop_max_turns orelse 8;

    try response.sendEventStreamHeaders(connection);

    const completion_id = try std.fmt.allocPrint(
        allocator,
        "chatcmpl-{d}",
        .{std.time.microTimestamp()},
    );
    defer allocator.free(completion_id);

    var working_messages = try session.cloneMessagesAlloc(allocator, base_request.messages);
    defer {
        for (working_messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(working_messages);
    }

    if (std.ascii.eqlIgnoreCase(loop_mode, "agent")) {
        const with_guidance = try appendRoleMessageAlloc(
            allocator,
            working_messages,
            "system",
            "You are running in API agent loop mode. Improve the answer each turn. Briefly self-critique then improve. Include the completion marker exactly when fully complete.",
        );
        for (working_messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(working_messages);
        working_messages = with_guidance;
    }

    var latest_user_prompt = try allocator.dupe(u8, base_request.prompt);
    defer allocator.free(latest_user_prompt);

    var previous_output: ?[]u8 = null;
    defer if (previous_output) |value| allocator.free(value);
    var repeated_count: usize = 0;

    var turn: usize = 0;
    while (turn < loop_max_turns) : (turn += 1) {
        var turn_request = try cloneRequestWithMessagesAlloc(allocator, base_request, latest_user_prompt, working_messages);
        defer turn_request.deinit(allocator);

        if (turn_request.loop_mode) |value| {
            allocator.free(value);
            turn_request.loop_mode = null;
        }
        if (turn_request.loop_until) |value| {
            allocator.free(value);
            turn_request.loop_until = null;
        }
        turn_request.loop_max_turns = null;

        var turn_result = try backend.callProvider(allocator, app_config, turn_request);
        defer turn_result.deinit(allocator);

        const with_assistant = try appendRoleMessageAlloc(
            allocator,
            working_messages,
            "assistant",
            turn_result.output,
        );
        for (working_messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(working_messages);
        working_messages = with_assistant;

        if (emit_progress) {
            const progress_text = try std.fmt.allocPrint(
                allocator,
                "[loop turn {d}/{d}]\n{s}\n",
                .{ turn + 1, loop_max_turns, turn_result.output },
            );
            defer allocator.free(progress_text);

            try response.sendChatCompletionChunkSse(
                connection,
                allocator,
                completion_id,
                turn_result.model,
                progress_text,
                null,
            );
        }

        const normalized_output = std.mem.trim(u8, turn_result.output, " \t\r\n");
        if (previous_output) |prev| {
            if (std.mem.eql(u8, prev, normalized_output)) {
                repeated_count += 1;
            } else {
                repeated_count = 0;
            }
            allocator.free(prev);
        }
        previous_output = try allocator.dupe(u8, normalized_output);

        const reached_until = std.mem.indexOf(u8, turn_result.output, loop_until) != null;
        const reached_max = (turn + 1) >= loop_max_turns;
        const repeated_stop = std.ascii.eqlIgnoreCase(loop_mode, "agent") and repeated_count >= 1;
        const should_stop = reached_until or reached_max or repeated_stop or !turn_result.success;

        if (should_stop) {
            if (!emit_progress and turn_result.output.len > 0) {
                try response.sendChatCompletionChunkSse(
                    connection,
                    allocator,
                    completion_id,
                    turn_result.model,
                    turn_result.output,
                    null,
                );
            }

            try response.sendChatCompletionChunkSse(
                connection,
                allocator,
                completion_id,
                turn_result.model,
                null,
                turn_result.finish_reason,
            );
            try response.sendSseDone(connection);
            return;
        }

        allocator.free(latest_user_prompt);
        latest_user_prompt = try allocator.dupe(
            u8,
            if (std.ascii.eqlIgnoreCase(loop_mode, "agent"))
                "Critique your previous answer briefly, then improve it with concrete next steps. If complete, include the completion marker exactly and return the final result."
            else
                "Continue.",
        );

        const with_continue = try appendRoleMessageAlloc(allocator, working_messages, "user", latest_user_prompt);
        for (working_messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(working_messages);
        working_messages = with_continue;
    }

    try response.sendSseDone(connection);
}

fn executeLoopRequestAlloc(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    base_request: types.Request,
) !LoopExecution {
    const loop_mode = base_request.loop_mode orelse "basic";
    const loop_until = base_request.loop_until orelse "DONE";
    const loop_max_turns = base_request.loop_max_turns orelse 8;

    var working_messages = try session.cloneMessagesAlloc(allocator, base_request.messages);
    errdefer {
        for (working_messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(working_messages);
    }

    if (std.ascii.eqlIgnoreCase(loop_mode, "agent")) {
        const with_guidance = try appendRoleMessageAlloc(
            allocator,
            working_messages,
            "system",
            "You are running in API agent loop mode. Improve the answer each turn. Briefly self-critique then improve. Include the completion marker exactly when fully complete.",
        );
        for (working_messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(working_messages);
        working_messages = with_guidance;
    }

    var latest_user_prompt = try allocator.dupe(u8, base_request.prompt);
    defer allocator.free(latest_user_prompt);

    var previous_output: ?[]u8 = null;
    defer if (previous_output) |value| allocator.free(value);
    var repeated_count: usize = 0;

    var turn: usize = 0;
    while (turn < loop_max_turns) : (turn += 1) {
        var turn_request = try cloneRequestWithMessagesAlloc(allocator, base_request, latest_user_prompt, working_messages);
        defer turn_request.deinit(allocator);

        if (turn_request.loop_mode) |value| {
            allocator.free(value);
            turn_request.loop_mode = null;
        }
        if (turn_request.loop_until) |value| {
            allocator.free(value);
            turn_request.loop_until = null;
        }
        turn_request.loop_max_turns = null;

        var turn_result = try backend.callProvider(allocator, app_config, turn_request);

        const with_assistant = try appendRoleMessageAlloc(
            allocator,
            working_messages,
            "assistant",
            turn_result.output,
        );
        for (working_messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(working_messages);
        working_messages = with_assistant;

        if (std.mem.indexOf(u8, turn_result.output, loop_until) != null) {
            return .{ .response = turn_result, .messages = working_messages };
        }

        if (!turn_result.success) {
            return .{ .response = turn_result, .messages = working_messages };
        }

        const normalized_output = std.mem.trim(u8, turn_result.output, " \t\r\n");
        if (previous_output) |prev| {
            if (std.mem.eql(u8, prev, normalized_output)) {
                repeated_count += 1;
            } else {
                repeated_count = 0;
            }
            allocator.free(prev);
        }
        previous_output = try allocator.dupe(u8, normalized_output);

        if (turn + 1 >= loop_max_turns) {
            return .{ .response = turn_result, .messages = working_messages };
        }

        if (std.ascii.eqlIgnoreCase(loop_mode, "agent") and repeated_count >= 1) {
            return .{ .response = turn_result, .messages = working_messages };
        }

        turn_result.deinit(allocator);

        allocator.free(latest_user_prompt);
        latest_user_prompt = try allocator.dupe(
            u8,
            if (std.ascii.eqlIgnoreCase(loop_mode, "agent"))
                "Critique your previous answer briefly, then improve it with concrete next steps. If complete, include the completion marker exactly and return the final result."
            else
                "Continue.",
        );

        const with_continue = try appendRoleMessageAlloc(allocator, working_messages, "user", latest_user_prompt);
        for (working_messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(working_messages);
        working_messages = with_continue;
    }

    return error.InvalidLoopState;
}

fn extractLastUserPromptAlloc(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
) ![]u8 {
    var i: usize = messages.len;
    while (i > 0) {
        i -= 1;
        if (std.ascii.eqlIgnoreCase(messages[i].role, "user")) {
            return try allocator.dupe(u8, messages[i].content);
        }
    }

    return try allocator.dupe(u8, "Continue.");
}

fn appendSystemMessageAlloc(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
    content: []const u8,
) ![]types.Message {
    var out = std.ArrayList(types.Message){};
    errdefer {
        for (out.items) |message| {
            message.deinit(allocator);
        }
        out.deinit(allocator);
    }

    for (messages) |message| {
        try out.append(allocator, .{
            .role = try allocator.dupe(u8, message.role),
            .content = try allocator.dupe(u8, message.content),
        });
    }

    try out.append(allocator, .{
        .role = try allocator.dupe(u8, "system"),
        .content = try allocator.dupe(u8, content),
    });

    return try out.toOwnedSlice(allocator);
}

fn appendRoleMessageAlloc(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
    role: []const u8,
    content: []const u8,
) ![]types.Message {
    var out = std.ArrayList(types.Message){};
    errdefer {
        for (out.items) |message| {
            message.deinit(allocator);
        }
        out.deinit(allocator);
    }

    for (messages) |message| {
        try out.append(allocator, .{
            .role = try allocator.dupe(u8, message.role),
            .content = try allocator.dupe(u8, message.content),
        });
    }

    try out.append(allocator, .{
        .role = try allocator.dupe(u8, role),
        .content = try allocator.dupe(u8, content),
    });

    return try out.toOwnedSlice(allocator);
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

test "connection gate enforces bounded capacity" {
    var gate = ConnectionGate{ .max_active = 2 };
    try std.testing.expect(gate.tryAcquire());
    try std.testing.expect(gate.tryAcquire());
    try std.testing.expect(!gate.tryAcquire());

    gate.release();
    try std.testing.expect(gate.tryAcquire());
}

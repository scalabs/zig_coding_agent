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
const workspace = @import("../backend/workspace.zig");
const react = @import("../react.zig");

const context_compaction_keep_messages = 8;
const max_recent_requests = 32;
const length_continue_prompt =
    "The previous assistant message was cut off by the generation limit. " ++
    "Continue the same answer from the exact next token. Output only the continuation text; " ++
    "do not mention truncation, continuation, the previous message, or these instructions.";

const RecentRequest = struct {
    route: [48]u8 = undefined,
    route_len: u8 = 0,
    status_code: u16 = 0,
    duration_ms: u64 = 0,
    request_id: [64]u8 = undefined,
    request_id_len: u8 = 0,
};

const ServerState = struct {
    mutex: std.Thread.Mutex = .{},
    total_requests: u64 = 0,
    successful_requests: u64 = 0,
    failed_requests: u64 = 0,
    active_connections: u64 = 0,
    provider_latency_buckets: [4]u64 = .{ 0, 0, 0, 0 },
    connected_clients: std.ArrayList([]u8),
    recent_requests: [max_recent_requests]RecentRequest = undefined,
    recent_request_idx: usize = 0,
    recent_request_count: usize = 0,

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

    fn noteProviderLatency(self: *ServerState, elapsed_ms: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const idx: usize = if (elapsed_ms < 50)
            0
        else if (elapsed_ms < 200)
            1
        else if (elapsed_ms < 1000)
            2
        else
            3;
        self.provider_latency_buckets[idx] += 1;
    }

    fn noteRecentRequest(
        self: *ServerState,
        route: []const u8,
        status_code: u16,
        duration_ms: u64,
        request_id: []const u8,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var entry = &self.recent_requests[self.recent_request_idx];
        const route_len = @min(route.len, entry.route.len);
        @memcpy(entry.route[0..route_len], route[0..route_len]);
        entry.route_len = @intCast(route_len);
        entry.status_code = status_code;
        entry.duration_ms = duration_ms;

        const request_id_len = @min(request_id.len, entry.request_id.len);
        @memcpy(entry.request_id[0..request_id_len], request_id[0..request_id_len]);
        entry.request_id_len = @intCast(request_id_len);

        self.recent_request_idx = (self.recent_request_idx + 1) % max_recent_requests;
        if (self.recent_request_count < max_recent_requests) {
            self.recent_request_count += 1;
        }
    }

    fn recentRequestsJsonAlloc(self: *ServerState, allocator: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8){};
        errdefer out.deinit(allocator);

        self.mutex.lock();
        defer self.mutex.unlock();

        try out.append(allocator, '[');
        var written: usize = 0;
        var idx = if (self.recent_request_count < max_recent_requests)
            0
        else
            self.recent_request_idx;

        while (written < self.recent_request_count) : ({
            written += 1;
            idx = (idx + 1) % max_recent_requests;
        }) {
            const entry = self.recent_requests[idx];
            if (written > 0) try out.append(allocator, ',');
            try out.writer(allocator).print(
                "{{\"route\":\"{s}\",\"status\":{d},\"duration_ms\":{d},\"request_id\":\"{s}\"}}",
                .{
                    entry.route[0..entry.route_len],
                    entry.status_code,
                    entry.duration_ms,
                    entry.request_id[0..entry.request_id_len],
                },
            );
        }
        try out.append(allocator, ']');
        return try out.toOwnedSlice(allocator);
    }

    fn snapshot(self: *ServerState) Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .total_requests = self.total_requests,
            .successful_requests = self.successful_requests,
            .failed_requests = self.failed_requests,
            .active_connections = self.active_connections,
            .provider_latency_buckets = self.provider_latency_buckets,
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
    provider_latency_buckets: [4]u64,
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
    workspace_store: ?*workspace.WorkspaceStore,
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
    logInfo("Default model: {s}", .{app_config.defaultModel()});
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
    try tool_registry.register(allocator, "file_read");
    try tool_registry.register(allocator, "file_write");
    try tool_registry.register(allocator, "file_search");

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

    var workspace_store_impl: ?workspace.WorkspaceStore = null;
    if (app_config.workspace_mode_enabled) {
        workspace_store_impl = workspace.WorkspaceStore.init(allocator);
        logInfo(
            "Workspace mode enabled root={s} (in-memory; cleared on exit)",
            .{app_config.workspace_root},
        );
    }
    defer if (workspace_store_impl) |*store| store.deinit();

    const active_session_store: ?*session.SessionStore = if (session_store) |*store| store else null;
    const active_workspace_store: ?*workspace.WorkspaceStore = if (workspace_store_impl) |*store| store else null;

    var gate = ConnectionGate{ .max_active = app_config.max_concurrent_connections };
    var session_store_guard = SessionStoreGuard{};
    const worker_context = WorkerContext{
        .allocator = allocator,
        .app_config = app_config,
        .server_state = &server_state,
        .tool_registry = &tool_registry,
        .session_store = active_session_store,
        .session_store_guard = &session_store_guard,
        .workspace_store = active_workspace_store,
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
                null,
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
        context.workspace_store,
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
    workspace_store: ?*workspace.WorkspaceStore,
) !void {
    const request_started_ms = std.time.milliTimestamp();
    var request_route: []const u8 = "unknown";
    var request_status: u16 = 500;
    var request_id_owned: ?[]u8 = null;
    defer if (request_id_owned) |id| allocator.free(id);
    defer server_state.noteRecentRequest(
        request_route,
        request_status,
        @intCast(@max(std.time.milliTimestamp() - request_started_ms, 0)),
        request_id_owned orelse "unknown",
    );

    // Translate transport-level parsing failures into OpenAI-style API errors.
    const request_raw = request.readHttpRequest(
        allocator,
        connection,
        app_config.request_timeout_ms,
        app_config.max_request_bytes,
        app_config.max_header_bytes,
    ) catch |err| switch (err) {
        error.ClientDisconnected => {
            debugLog(app_config, "client disconnected before full request", .{});
            return;
        },
        error.RequestTimedOut => {
            sendApiErrorSafe(connection.*, allocator, backend.errors.requestTimeoutError(), app_config, null);
            return;
        },
        error.RequestTooLarge => {
            sendApiErrorSafe(connection.*, allocator, backend.errors.payloadTooLargeError(), app_config, null);
            return;
        },
        error.HeadersTooLarge => {
            sendApiErrorSafe(connection.*, allocator, backend.errors.httpError(
                "HTTP headers are too large",
                "headers_too_large",
            ), app_config, null);
            return;
        },
        error.InvalidHttpRequest => {
            sendApiErrorSafe(connection.*, allocator, backend.errors.httpError(
                "Malformed HTTP request",
                "invalid_http_request",
            ), app_config, null);
            return;
        },
        error.MissingContentLength => {
            sendApiErrorSafe(connection.*, allocator, backend.errors.httpError(
                "Missing Content-Length header",
                "missing_content_length",
            ), app_config, null);
            return;
        },
        error.InvalidContentLength => {
            sendApiErrorSafe(connection.*, allocator, backend.errors.httpError(
                "Invalid Content-Length header",
                "invalid_content_length",
            ), app_config, null);
            return;
        },
        error.IncompleteRequestBody => {
            sendApiErrorSafe(connection.*, allocator, backend.errors.httpError(
                "Incomplete request body",
                "incomplete_body",
            ), app_config, null);
            return;
        },
        else => {
            debugLog(app_config, "unhandled socket read error: {s}", .{@errorName(err)});
            return;
        },
    };
    defer allocator.free(request_raw);

    request_id_owned = try request.resolveRequestIdAlloc(allocator, request_raw);
    const request_id = request_id_owned.?;

    const header_end = std.mem.indexOf(u8, request_raw, "\r\n\r\n") orelse request_raw.len;
    if (request.getHeaderValue(request_raw[0..header_end], "User-Agent")) |user_agent| {
        server_state.noteClient(allocator, user_agent) catch {};
    }

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
        ), app_config, request_id);
        server_state.noteRequestFailed();
        return;
    };

    if (route == null) {
        sendApiErrorSafe(connection.*, allocator, backend.errors.notFoundError(), app_config, request_id);
        server_state.noteRequestFailed();
        return;
    }

    request_route = switch (route.?) {
        .health => "GET /health",
        .metrics => "GET /metrics",
        .diagnostics_clients => "GET /diagnostics/clients",
        .diagnostics_requests => "GET /diagnostics/requests",
        .diagnostics_providers => "GET /diagnostics/providers",
        .chat_completions => "POST /v1/chat/completions",
    };

    if (requiresAuth(route.?) and auth.authorizeRequest(app_config.auth_api_key, request_raw) == .denied) {
        sendJsonSafe(connection.*, 401, "{\"error\":{\"message\":\"Unauthorized\",\"type\":\"auth_error\",\"param\":null,\"code\":\"unauthorized\"}}", app_config, request_id);
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
            sendJsonSafe(connection.*, 200, health_json, app_config, request_id);
            server_state.noteRequestSucceeded();
            return;
        },
        .metrics => {
            const snapshot = server_state.snapshot();
            const metrics_json = try std.fmt.allocPrint(
                allocator,
                "{{\"instance_id\":\"{s}\",\"total_requests\":{d},\"successful_requests\":{d},\"failed_requests\":{d},\"active_connections\":{d},\"provider_latency_buckets_ms\":{{\"lt_50\":{d},\"lt_200\":{d},\"lt_1000\":{d},\"gte_1000\":{d}}}}}",
                .{
                    app_config.instance_id,
                    snapshot.total_requests,
                    snapshot.successful_requests,
                    snapshot.failed_requests,
                    snapshot.active_connections,
                    snapshot.provider_latency_buckets[0],
                    snapshot.provider_latency_buckets[1],
                    snapshot.provider_latency_buckets[2],
                    snapshot.provider_latency_buckets[3],
                },
            );
            defer allocator.free(metrics_json);
            sendJsonSafe(connection.*, 200, metrics_json, app_config, request_id);
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
            sendJsonSafe(connection.*, 200, payload, app_config, request_id);
            server_state.noteRequestSucceeded();
            return;
        },
        .diagnostics_requests => {
            const snapshot = server_state.snapshot();
            const recent_json = try server_state.recentRequestsJsonAlloc(allocator);
            defer allocator.free(recent_json);
            const payload = try std.fmt.allocPrint(
                allocator,
                "{{\"instance_id\":\"{s}\",\"total_requests\":{d},\"successful_requests\":{d},\"failed_requests\":{d},\"recent_requests\":{s}}}",
                .{
                    app_config.instance_id,
                    snapshot.total_requests,
                    snapshot.successful_requests,
                    snapshot.failed_requests,
                    recent_json,
                },
            );
            defer allocator.free(payload);
            sendJsonSafe(connection.*, 200, payload, app_config, null);
            server_state.noteRequestSucceeded();
            request_status = 200;
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

            sendJsonSafe(connection.*, 200, payload, app_config, request_id);
            server_state.noteRequestSucceeded();
            return;
        },
        .chat_completions => {},
    }

    const body = request.findBody(request_raw) orelse {
        sendApiErrorSafe(connection.*, allocator, backend.errors.httpError(
            "Missing request body",
            "missing_body",
        ), app_config, request_id);
        server_state.noteRequestFailed();
        return;
    };

    debugLog(app_config, "request body_len={d}", .{body.len});

    const parse_result = try backend.parseChatRequest(allocator, body);
    var parsed_req = switch (parse_result) {
        .ok => |parsed_request| parsed_request,
        .err => |api_error| {
            sendApiErrorSafe(connection.*, allocator, api_error, app_config, request_id);
            server_state.noteRequestFailed();
            return;
        },
    };
    defer parsed_req.deinit(allocator);

    react.ensureReactCodingToolsAlloc(allocator, &parsed_req) catch |err| {
        logError("ReAct tool augmentation failed: {s}", .{@errorName(err)});
        sendApiErrorSafe(
            connection.*,
            allocator,
            backend.errors.httpError("Failed to prepare ReAct coding tools", "react_tool_setup_failed"),
            app_config,
            request_id,
        );
        server_state.noteRequestFailed();
        return;
    };

    if (!tooling.validateRequestedTools(tool_registry, parsed_req.tools)) {
        sendApiErrorSafe(connection.*, allocator, backend.errors.validationError(
            "One or more requested tools are not registered",
            "tools",
            "unknown_tool",
        ), app_config, request_id);
        server_state.noteRequestFailed();
        return;
    }

    var loaded_session: ?session.SessionState = null;
    defer if (loaded_session) |state| state.deinit(allocator);

    var active_workspace: ?*workspace.WorkspaceState = null;
    const use_workspace = app_config.workspace_mode_enabled and parsed_req.workspace_id != null;

    var request_messages = try session.cloneMessagesAlloc(allocator, parsed_req.messages);
    defer {
        for (request_messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(request_messages);
    }

    var request_prompt = try allocator.dupe(u8, parsed_req.prompt);
    defer allocator.free(request_prompt);

    if (use_workspace) {
        if (workspace_store) |store| {
            active_workspace = try store.getOrCreate(parsed_req.workspace_id.?);
            if (active_workspace.?.messages.len > 0) {
                const merged_messages = try workspace.mergeIncomingMessagesAlloc(
                    allocator,
                    active_workspace.?.messages,
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

            const with_hint = try workspace.prependMemoryHintAlloc(allocator, active_workspace.?, request_messages);
            for (request_messages) |message| {
                message.deinit(allocator);
            }
            allocator.free(request_messages);
            request_messages = with_hint;

            allocator.free(request_prompt);
            request_prompt = try extractLastUserPromptAlloc(allocator, request_messages);
        }
    } else if (session_store) |store| {
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

    const effective_max_context_tokens = parsed_req.max_context_tokens orelse app_config.default_max_context_tokens;

    if (effective_max_context_tokens) |max_tokens| {
        const estimated = session.estimateTokenCount(request_messages);
        if (session.shouldCompressContext(estimated, max_tokens)) {
            const compacted_messages = try session.compactContextToBudgetAlloc(
                allocator,
                request_messages,
                max_tokens,
                context_compaction_keep_messages,
            );

            for (request_messages) |message| {
                message.deinit(allocator);
            }
            allocator.free(request_messages);
            request_messages = compacted_messages;

            allocator.free(request_prompt);
            request_prompt = try extractLastUserPromptAlloc(allocator, request_messages);

            debugLog(
                app_config,
                "context compacted estimated_tokens={d} compacted_tokens={d} max_context_tokens={d}",
                .{ estimated, session.estimateTokenCount(request_messages), max_tokens },
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

        var stream_request = try cloneRequestWithMessagesAlloc(
            allocator,
            parsed_req,
            request_prompt,
            request_messages,
        );
        defer stream_request.deinit(allocator);

        if (try tooling.tryExecuteDebugTool(allocator, stream_request, app_config, request_id, active_workspace)) |tool_result| {
            defer tool_result.deinit(allocator);

            try response.sendEventStreamHeaders(connection.*, request_id);
            const completion_id = try std.fmt.allocPrint(
                allocator,
                "chatcmpl-{d}",
                .{std.time.microTimestamp()},
            );
            defer allocator.free(completion_id);

            try response.sendChatCompletionChunkSse(
                connection.*,
                allocator,
                completion_id,
                tool_result.model,
                tool_result.output,
                null,
            );
            try response.sendChatCompletionChunkSse(
                connection.*,
                allocator,
                completion_id,
                tool_result.model,
                null,
                tool_result.finish_reason,
            );
            try response.sendSseDone(connection.*);

            server_state.noteRequestSucceeded();
            return;
        }

        if (!std.mem.eql(u8, normalized_provider, "ollama_qwen")) {
            sendApiErrorSafe(connection.*, allocator, backend.errors.validationError(
                "stream=true is currently supported only for ollama",
                "stream",
                "unsupported_stream_provider",
            ), app_config, request_id);
            server_state.noteRequestFailed();
            return;
        }

        const stream_auto_tool_summary = tooling.maybeExecutePromptToolsAlloc(allocator, stream_request, app_config, request_id, active_workspace) catch |err| switch (err) {
            error.ToolCallLimitExceeded => {
                sendApiErrorSafe(connection.*, allocator, backend.errors.validationError(
                    "Tool call limit exceeded",
                    "tools",
                    "tool_call_limit_exceeded",
                ), app_config, request_id);
                server_state.noteRequestFailed();
                return;
            },
            else => return err,
        };
        defer if (stream_auto_tool_summary) |summary| allocator.free(summary);

        if (stream_auto_tool_summary) |summary| {
            if (tooling.shouldShortCircuitAutoTools(stream_request)) {
                try response.sendEventStreamHeaders(connection.*, request_id);
                const completion_id = try std.fmt.allocPrint(
                    allocator,
                    "chatcmpl-{d}",
                    .{std.time.microTimestamp()},
                );
                defer allocator.free(completion_id);

                try response.sendChatCompletionChunkSse(
                    connection.*,
                    allocator,
                    completion_id,
                    "debug-tools/auto",
                    summary,
                    null,
                );
                try response.sendChatCompletionChunkSse(
                    connection.*,
                    allocator,
                    completion_id,
                    "debug-tools/auto",
                    null,
                    "tool",
                );
                try response.sendSseDone(connection.*);
                server_state.noteRequestSucceeded();
                return;
            }

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
                request_id,
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
                ), app_config, request_id);
                server_state.noteRequestFailed();
                return;
            },
        }
    }

    if (try tooling.tryExecuteDebugTool(allocator, parsed_req, app_config, request_id, active_workspace)) |tool_result| {
        defer tool_result.deinit(allocator);
        debugLog(
            app_config,
            "debug tool executed tool_choice={s}",
            .{parsed_req.tool_choice orelse "(none)"},
        );
        persistConversationState(
            allocator,
            app_config,
            use_workspace,
            workspace_store,
            active_workspace,
            session_store,
            session_store_guard,
            parsed_req,
            loaded_session,
            request_messages,
            null,
            tool_result.output,
        );
        sendChatCompletionSafe(connection.*, allocator, tool_result, app_config, request_id);
        server_state.noteRequestSucceeded();
        request_status = 200;
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

    const auto_tool_summary = tooling.maybeExecutePromptToolsAlloc(allocator, provider_request, app_config, request_id, active_workspace) catch |err| switch (err) {
        error.ToolCallLimitExceeded => {
            sendApiErrorSafe(connection.*, allocator, backend.errors.validationError(
                "Tool call limit exceeded",
                "tools",
                "tool_call_limit_exceeded",
            ), app_config, request_id);
            server_state.noteRequestFailed();
            return;
        },
        else => return err,
    };
    defer if (auto_tool_summary) |summary| allocator.free(summary);

    if (auto_tool_summary) |summary| {
        if (tooling.shouldShortCircuitAutoTools(provider_request)) {
            var tool_response = try tooling.makeAutoToolResponse(allocator, summary);
            defer tool_response.deinit(allocator);
            persistConversationState(
                allocator,
                app_config,
                use_workspace,
                workspace_store,
                active_workspace,
                session_store,
                session_store_guard,
                parsed_req,
                loaded_session,
                provider_request.messages,
                null,
                tool_response.output,
            );
            sendChatCompletionSafe(connection.*, allocator, tool_response, app_config, request_id);
            server_state.noteRequestSucceeded();
            request_status = 200;
            return;
        }
    }

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
        const loop_execution = executeLoopRequestAlloc(allocator, app_config, provider_request, request_id) catch |err| {
            if (err == error.ToolCallLimitExceeded) {
                sendApiErrorSafe(
                    connection.*,
                    allocator,
                    backend.errors.validationError("Tool call limit exceeded", "tools", "tool_call_limit_exceeded"),
                    app_config,
                    request_id,
                );
                server_state.noteRequestFailed();
                return;
            }
            logError("Provider loop request error: {}", .{err});
            sendApiErrorSafe(
                connection.*,
                allocator,
                backend.errors.providerTransportError(@errorName(err)),
                app_config,
                request_id,
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
                request_id,
            );
            server_state.noteRequestFailed();
            return;
        };
        result_ready = true;
    }

    const provider_elapsed_ms: u64 = @intCast(@max(std.time.milliTimestamp() - provider_started_ms, 0));
    server_state.noteProviderLatency(provider_elapsed_ms);
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
            request_id,
        );
        server_state.noteRequestFailed();
        return;
    }

    if (!loop_enabled and isLengthFinishReason(result.finish_reason)) {
        continueLengthResponseAlloc(allocator, app_config, provider_request, &result) catch |err| {
            logError("Provider continuation failed: {s}", .{@errorName(err)});
        };
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
                request_id,
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
        if (!use_workspace and parsed_req.session_id != null) {
            persistConversationState(
                allocator,
                app_config,
                false,
                workspace_store,
                active_workspace,
                store,
                session_store_guard,
                parsed_req,
                loaded_session,
                provider_request.messages,
                loop_messages_for_persistence,
                result.output,
            );
        }
    }

    if (use_workspace) {
        persistConversationState(
            allocator,
            app_config,
            true,
            workspace_store,
            active_workspace,
            session_store,
            session_store_guard,
            parsed_req,
            loaded_session,
            provider_request.messages,
            loop_messages_for_persistence,
            result.output,
        );
    }

    sendChatCompletionSafe(connection.*, allocator, result, app_config, request_id);
    server_state.noteRequestSucceeded();
    request_status = 200;
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
        .workspace_id = if (parsed_req.workspace_id) |workspace_id| try allocator.dupe(u8, workspace_id) else null,
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

const agent_loop_guidance =
    "You are running in API agent loop mode. Improve the answer each turn. Briefly self-critique then improve. Include the completion marker exactly when fully complete.";

const agent_continue_prompt =
    "Critique your previous answer briefly, then improve it with concrete next steps. If complete, include the completion marker exactly and return the final result.";

const react_loop_default_max_turns: usize = 24;
const react_repeated_stop_threshold: usize = 2;

fn resolveLoopMaxTurns(loop_mode: []const u8, explicit: ?usize) usize {
    if (explicit) |value| return value;
    if (std.ascii.eqlIgnoreCase(loop_mode, "react")) return react_loop_default_max_turns;
    return 8;
}

fn reactToolCallBudget(app_config: *const config.Config, loop_max_turns: usize) usize {
    return @max(app_config.max_tool_calls_per_request, loop_max_turns);
}

fn maybeCompactLoopWorkingMessages(
    allocator: std.mem.Allocator,
    working_messages: *[]types.Message,
    max_context_tokens: ?usize,
) !void {
    const max_tokens = max_context_tokens orelse return;
    const estimated = session.estimateTokenCount(working_messages.*);
    if (!session.shouldCompressContext(estimated, max_tokens)) return;

    const compacted = try session.compactContextToBudgetAlloc(
        allocator,
        working_messages.*,
        max_tokens,
        context_compaction_keep_messages,
    );

    for (working_messages.*) |message| {
        message.deinit(allocator);
    }
    allocator.free(working_messages.*);
    working_messages.* = compacted;
}

fn prepareLoopWorkingMessagesAlloc(
    allocator: std.mem.Allocator,
    base_request: types.Request,
    loop_mode: []const u8,
) ![]types.Message {
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
            agent_loop_guidance,
        );
        for (working_messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(working_messages);
        working_messages = with_guidance;
    } else if (std.ascii.eqlIgnoreCase(loop_mode, "react")) {
        const react_prompt = try react.buildSystemPromptAlloc(allocator, base_request.tools);
        defer allocator.free(react_prompt);
        const with_react = try appendRoleMessageAlloc(
            allocator,
            working_messages,
            "system",
            react_prompt,
        );
        for (working_messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(working_messages);
        working_messages = with_react;
    }

    return working_messages;
}

fn nextBasicLoopPromptAlloc(allocator: std.mem.Allocator, loop_mode: []const u8) ![]u8 {
    return try allocator.dupe(
        u8,
        if (std.ascii.eqlIgnoreCase(loop_mode, "agent")) agent_continue_prompt else "Continue.",
    );
}

fn providerRequestForLoopTurn(
    turn_request: types.Request,
    loop_mode: []const u8,
) types.Request {
    if (!std.ascii.eqlIgnoreCase(loop_mode, "react")) return turn_request;

    // ReAct advertises tools in the system prompt and parses actions locally.
    // Do not forward tools upstream or providers activate tool templates that
    // break on prior assistant messages.
    var r = turn_request;
    r.tools = &.{};
    r.tool_choice = null;
    return r;
}

fn reactToolPromptAlloc(
    allocator: std.mem.Allocator,
    action: react.ReactAction,
    tools: []const types.Tool,
) !?[]u8 {
    return switch (action) {
        .search => |query| blk: {
            if (!tooling.hasRequestedTool(tools, "file_search")) break :blk null;
            break :blk try std.fmt.allocPrint(allocator, "search {s} in .", .{query});
        },
        .lookup => |path| blk: {
            if (!tooling.hasRequestedTool(tools, "file_read")) break :blk null;
            break :blk try std.fmt.allocPrint(allocator, "read {s}", .{path});
        },
        .tool => |tool_action| blk: {
            if (std.ascii.eqlIgnoreCase(tool_action.name, "file_read")) {
                const trimmed = std.mem.trim(u8, tool_action.argument, " \t\r\n\"'");
                if (std.ascii.startsWithIgnoreCase(trimmed, "read ") or
                    std.ascii.startsWithIgnoreCase(trimmed, "file_read "))
                {
                    break :blk try allocator.dupe(u8, trimmed);
                }
                break :blk try std.fmt.allocPrint(allocator, "read {s}", .{trimmed});
            }
            if (std.ascii.eqlIgnoreCase(tool_action.name, "file_write")) {
                const trimmed = std.mem.trim(u8, tool_action.argument, " \t\r\n");
                if (std.ascii.startsWithIgnoreCase(trimmed, "write ")) {
                    break :blk try allocator.dupe(u8, trimmed);
                }
                break :blk try std.fmt.allocPrint(allocator, "write {s}", .{trimmed});
            }
            if (std.ascii.eqlIgnoreCase(tool_action.name, "file_search")) {
                const trimmed = std.mem.trim(u8, tool_action.argument, " \t\r\n\"'");
                if (std.ascii.startsWithIgnoreCase(trimmed, "search ") or
                    std.ascii.startsWithIgnoreCase(trimmed, "file_search "))
                {
                    break :blk try allocator.dupe(u8, trimmed);
                }
                break :blk try std.fmt.allocPrint(allocator, "search {s} in .", .{trimmed});
            }
            break :blk try allocator.dupe(u8, tool_action.argument);
        },
        else => null,
    };
}

fn executeReactActionForRequest(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    turn_request: types.Request,
    tool_messages: []const types.Message,
    action: react.ReactAction,
    request_id: []const u8,
) ![]u8 {
    if (try reactToolPromptAlloc(allocator, action, turn_request.tools)) |mapped_prompt| {
        defer allocator.free(mapped_prompt);

        const tool_name: []const u8 = switch (action) {
            .search => "file_search",
            .lookup => "file_read",
            .tool => |tool_action| tool_action.name,
            else => unreachable,
        };

        var tool_request = try cloneRequestWithMessagesAlloc(
            allocator,
            turn_request,
            mapped_prompt,
            tool_messages,
        );
        defer tool_request.deinit(allocator);

        if (tool_request.tool_choice) |value| {
            allocator.free(value);
        }
        tool_request.tool_choice = try allocator.dupe(u8, tool_name);

        if (try tooling.tryExecuteDebugTool(allocator, tool_request, app_config, request_id, null)) |tool_result| {
            defer tool_result.deinit(allocator);
            return try allocator.dupe(u8, tool_result.output);
        }

        return try std.fmt.allocPrint(
            allocator,
            "Tool action {s} was not requested or its input could not be parsed.",
            .{tool_name},
        );
    }

    return switch (action) {
        .tool => |tool_action| blk: {
            var tool_request = try cloneRequestWithMessagesAlloc(
                allocator,
                turn_request,
                tool_action.argument,
                tool_messages,
            );
            defer tool_request.deinit(allocator);

            if (tool_request.tool_choice) |value| {
                allocator.free(value);
            }
            tool_request.tool_choice = try allocator.dupe(u8, tool_action.name);

            if (try tooling.tryExecuteDebugTool(allocator, tool_request, app_config, request_id, null)) |tool_result| {
                defer tool_result.deinit(allocator);
                break :blk try allocator.dupe(u8, tool_result.output);
            }

            break :blk try std.fmt.allocPrint(
                allocator,
                "Tool action {s} was not requested or its input could not be parsed.",
                .{tool_action.name},
            );
        },
        else => try react.executeReactAction(allocator, action, app_config),
    };
}

fn streamLoopRequestToSse(
    connection: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    base_request: types.Request,
    emit_progress: bool,
    request_id: []const u8,
) !void {
    const loop_mode = base_request.loop_mode orelse "basic";
    const loop_until = base_request.loop_until orelse "DONE";
    const loop_max_turns = resolveLoopMaxTurns(loop_mode, base_request.loop_max_turns);
    const effective_max_context_tokens = base_request.max_context_tokens orelse app_config.default_max_context_tokens;
    const react_tool_budget = reactToolCallBudget(app_config, loop_max_turns);

    try response.sendEventStreamHeaders(connection, request_id);
    var headers_sent: bool = true;
    var think_block_open: bool = false;

    const completion_id = try std.fmt.allocPrint(
        allocator,
        "chatcmpl-{d}",
        .{std.time.microTimestamp()},
    );
    defer allocator.free(completion_id);

    var working_messages = try prepareLoopWorkingMessagesAlloc(allocator, base_request, loop_mode);
    defer {
        for (working_messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(working_messages);
    }

    var latest_user_prompt = try allocator.dupe(u8, base_request.prompt);
    defer allocator.free(latest_user_prompt);

    var previous_output: ?[]u8 = null;
    defer if (previous_output) |value| allocator.free(value);
    var repeated_count: usize = 0;
    var react_tool_calls: usize = 0;

    var turn: usize = 0;
    while (turn < loop_max_turns) : (turn += 1) {
        try maybeCompactLoopWorkingMessages(allocator, &working_messages, effective_max_context_tokens);

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

        const provider_request = providerRequestForLoopTurn(turn_request, loop_mode);

        // Emit the per-turn header BEFORE provider tokens stream in, so the
        // client can render "[loop turn N/M]\n" then watch tokens arrive live.
        if (emit_progress) {
            const progress_prefix = try std.fmt.allocPrint(
                allocator,
                "[loop turn {d}/{d}]\n",
                .{ turn + 1, loop_max_turns },
            );
            defer allocator.free(progress_prefix);

            try response.sendChatCompletionChunkSse(
                connection,
                allocator,
                completion_id,
                provider_request.model orelse app_config.modelForProvider(
                    provider_request.provider orelse app_config.default_provider,
                ),
                progress_prefix,
                null,
            );
        }

        var turn_outcome = try backend.streamProviderTurn(
            connection,
            allocator,
            app_config,
            provider_request,
            completion_id,
            &headers_sent,
            &think_block_open,
        );
        defer turn_outcome.deinit(allocator);

        // Emit a trailing newline after the turn body so progress text and
        // the next observation/prefix don't visually collide.
        if (emit_progress and turn_outcome.captured_content.len > 0) {
            try response.sendChatCompletionChunkSse(
                connection,
                allocator,
                completion_id,
                turn_outcome.model,
                "\n",
                null,
            );
        }

        const with_assistant = try appendRoleMessageAlloc(
            allocator,
            working_messages,
            "assistant",
            turn_outcome.captured_content,
        );
        for (working_messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(working_messages);
        working_messages = with_assistant;

        const normalized_output = std.mem.trim(u8, turn_outcome.captured_content, " \t\r\n");
        if (previous_output) |prev| {
            if (std.mem.eql(u8, prev, normalized_output)) {
                repeated_count += 1;
            } else {
                repeated_count = 0;
            }
            allocator.free(prev);
        }
        previous_output = try allocator.dupe(u8, normalized_output);

        const is_react_mode = std.ascii.eqlIgnoreCase(loop_mode, "react");
        const reached_until = std.mem.indexOf(u8, turn_outcome.captured_content, loop_until) != null;
        const reached_max = (turn + 1) >= loop_max_turns;
        const repeated_stop = blk: {
            if (is_react_mode) break :blk repeated_count >= react_repeated_stop_threshold;
            if (std.ascii.eqlIgnoreCase(loop_mode, "agent")) break :blk repeated_count >= 1;
            break :blk false;
        };

        // ReAct: check for Finish action before standard stop checks.
        var react_finished = false;
        var react_observation: ?[]u8 = null;
        defer if (react_observation) |obs| allocator.free(obs);

        if (is_react_mode) {
            if (react.parseReactAction(turn_outcome.captured_content)) |action| {
                switch (action) {
                    .finish => {
                        react_finished = true;
                    },
                    else => {
                        try tooling.noteToolCall(react_tool_budget, &react_tool_calls);
                        const obs_raw = try executeReactActionForRequest(allocator, app_config, turn_request, working_messages, action, request_id);
                        defer allocator.free(obs_raw);
                        react_observation = try react.formatObservation(allocator, turn + 1, obs_raw);
                    },
                }
            } else {
                react_observation = try react.formatObservation(
                    allocator,
                    turn + 1,
                    react.parse_error_hint,
                );
            }
        }

        const should_stop = react_finished or reached_until or reached_max or repeated_stop or !turn_outcome.success;

        if (should_stop) {
            // Close any dangling <think> block from the last turn so the
            // client doesn't render an unterminated reasoning section.
            if (think_block_open) {
                try response.sendChatCompletionChunkSse(
                    connection, allocator, completion_id, turn_outcome.model, "</think>", null,
                );
                think_block_open = false;
            }

            try response.sendChatCompletionChunkSse(
                connection,
                allocator,
                completion_id,
                turn_outcome.model,
                null,
                turn_outcome.finish_reason,
            );
            try response.sendSseDone(connection);
            return;
        }

        allocator.free(latest_user_prompt);

        if (is_react_mode) {
            // Inject the observation as the next user prompt.
            const obs = react_observation orelse try allocator.dupe(u8, "Continue.");
            react_observation = null; // Transfer ownership.
            latest_user_prompt = obs;

            if (emit_progress) {
                try response.sendChatCompletionChunkSse(
                    connection,
                    allocator,
                    completion_id,
                    turn_outcome.model,
                    latest_user_prompt,
                    null,
                );
            }
        } else {
            latest_user_prompt = try nextBasicLoopPromptAlloc(allocator, loop_mode);
        }

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
    request_id: []const u8,
) !LoopExecution {
    const loop_mode = base_request.loop_mode orelse "basic";
    const loop_until = base_request.loop_until orelse "DONE";
    const loop_max_turns = resolveLoopMaxTurns(loop_mode, base_request.loop_max_turns);
    const effective_max_context_tokens = base_request.max_context_tokens orelse app_config.default_max_context_tokens;
    const react_tool_budget = reactToolCallBudget(app_config, loop_max_turns);

    var working_messages = try prepareLoopWorkingMessagesAlloc(allocator, base_request, loop_mode);
    errdefer {
        for (working_messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(working_messages);
    }

    var latest_user_prompt = try allocator.dupe(u8, base_request.prompt);
    defer allocator.free(latest_user_prompt);

    var previous_output: ?[]u8 = null;
    defer if (previous_output) |value| allocator.free(value);
    var repeated_count: usize = 0;
    var react_tool_calls: usize = 0;

    var turn: usize = 0;
    while (turn < loop_max_turns) : (turn += 1) {
        try maybeCompactLoopWorkingMessages(allocator, &working_messages, effective_max_context_tokens);

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

        // See streamLoopRequestToSse: strip tools/tool_choice from the
        // upstream call in ReAct mode to avoid provider-side tool templates.
        const provider_request = providerRequestForLoopTurn(turn_request, loop_mode);

        var turn_result = try backend.callProvider(allocator, app_config, provider_request);
        if (turn_result.success and isLengthFinishReason(turn_result.finish_reason)) {
            continueLengthResponseAlloc(allocator, app_config, provider_request, &turn_result) catch |err| {
                logError("Provider loop continuation failed: {s}", .{@errorName(err)});
            };
        }

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

        // ReAct mode: parse action, execute, inject observation.
        const is_react_mode = std.ascii.eqlIgnoreCase(loop_mode, "react");
        var react_observation: ?[]u8 = null;
        var react_finished = false;
        defer if (react_observation) |obs| allocator.free(obs);

        if (is_react_mode) {
            if (repeated_count >= react_repeated_stop_threshold) {
                return .{ .response = turn_result, .messages = working_messages };
            }

            if (react.parseReactAction(turn_result.output)) |action| {
                switch (action) {
                    .finish => {
                        react_finished = true;
                    },
                    else => {
                        try tooling.noteToolCall(react_tool_budget, &react_tool_calls);
                        const obs_raw = try executeReactActionForRequest(allocator, app_config, turn_request, working_messages, action, request_id);
                        defer allocator.free(obs_raw);
                        react_observation = try react.formatObservation(allocator, turn + 1, obs_raw);
                    },
                }
            } else {
                react_observation = try react.formatObservation(
                    allocator,
                    turn + 1,
                    react.parse_error_hint,
                );
            }

            if (react_finished) {
                return .{ .response = turn_result, .messages = working_messages };
            }
        }

        turn_result.deinit(allocator);

        allocator.free(latest_user_prompt);

        if (is_react_mode) {
            const obs = react_observation orelse try allocator.dupe(u8, "Continue.");
            react_observation = null; // Transfer ownership.
            latest_user_prompt = obs;
        } else {
            latest_user_prompt = try nextBasicLoopPromptAlloc(allocator, loop_mode);
        }

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

fn continueLengthResponseAlloc(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    base_request: types.Request,
    result: *types.Response,
) !void {
    const max_continuations: usize = 4;
    var working_messages = try session.cloneMessagesAlloc(allocator, base_request.messages);
    defer {
        for (working_messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(working_messages);
    }

    const with_first_assistant = try appendRoleMessageAlloc(allocator, working_messages, "assistant", result.output);
    for (working_messages) |message| {
        message.deinit(allocator);
    }
    allocator.free(working_messages);
    working_messages = with_first_assistant;

    var turn: usize = 0;
    while (turn < max_continuations and isLengthFinishReason(result.finish_reason)) : (turn += 1) {
        const continue_prompt = length_continue_prompt;
        const with_continue = try appendRoleMessageAlloc(allocator, working_messages, "user", continue_prompt);
        for (working_messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(working_messages);
        working_messages = with_continue;

        var turn_request = try cloneRequestWithMessagesAlloc(allocator, base_request, continue_prompt, working_messages);
        defer turn_request.deinit(allocator);

        var turn_result = try backend.callProvider(allocator, app_config, turn_request);
        defer turn_result.deinit(allocator);
        if (!turn_result.success) return;
        if (std.mem.trim(u8, turn_result.output, " \t\r\n").len == 0) return;

        const joined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ result.output, turn_result.output });
        allocator.free(result.output);
        result.output = joined;

        allocator.free(result.finish_reason);
        result.finish_reason = try allocator.dupe(u8, turn_result.finish_reason);
        result.usage.prompt_tokens += turn_result.usage.prompt_tokens;
        result.usage.completion_tokens += turn_result.usage.completion_tokens;
        result.usage.total_tokens += turn_result.usage.total_tokens;

        const with_assistant = try appendRoleMessageAlloc(allocator, working_messages, "assistant", turn_result.output);
        for (working_messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(working_messages);
        working_messages = with_assistant;
    }
}

fn isLengthFinishReason(finish_reason: []const u8) bool {
    return std.ascii.eqlIgnoreCase(finish_reason, "length");
}

fn persistConversationState(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    use_workspace: bool,
    workspace_store: ?*workspace.WorkspaceStore,
    active_workspace: ?*workspace.WorkspaceState,
    session_store: ?*session.SessionStore,
    session_store_guard: *SessionStoreGuard,
    parsed_req: types.Request,
    loaded_session: ?session.SessionState,
    base_messages: []const types.Message,
    loop_messages: ?[]types.Message,
    assistant_output: []const u8,
) void {
    if (use_workspace) {
        persistWorkspaceState(
            allocator,
            workspace_store,
            active_workspace,
            base_messages,
            loop_messages,
            assistant_output,
        );
        return;
    }

    persistSessionState(
        allocator,
        app_config,
        session_store,
        session_store_guard,
        parsed_req,
        loaded_session,
        base_messages,
        loop_messages,
        assistant_output,
    );
}

fn persistWorkspaceState(
    allocator: std.mem.Allocator,
    workspace_store: ?*workspace.WorkspaceStore,
    active_workspace: ?*workspace.WorkspaceState,
    base_messages: []const types.Message,
    loop_messages: ?[]types.Message,
    assistant_output: []const u8,
) void {
    const store = workspace_store orelse return;
    const ws = active_workspace orelse return;

    const with_assistant = if (loop_messages) |messages| blk: {
        break :blk session.cloneMessagesAlloc(allocator, messages) catch |err| blk2: {
            logError("Workspace append failed: {s}", .{@errorName(err)});
            break :blk2 null;
        };
    } else session.appendAssistantMessageAlloc(
        allocator,
        base_messages,
        assistant_output,
    ) catch |err| blk: {
        logError("Workspace append failed: {s}", .{@errorName(err)});
        break :blk null;
    };

    if (with_assistant) |messages| {
        store.saveMessages(ws, messages) catch |err| {
            logError("Workspace save failed: {s}", .{@errorName(err)});
            for (messages) |message| {
                message.deinit(allocator);
            }
            allocator.free(messages);
        };
    }
}

fn persistSessionState(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    session_store: ?*session.SessionStore,
    session_store_guard: *SessionStoreGuard,
    parsed_req: types.Request,
    loaded_session: ?session.SessionState,
    base_messages: []const types.Message,
    loop_messages: ?[]types.Message,
    assistant_output: []const u8,
) void {
    const store = session_store orelse return;
    const session_id = parsed_req.session_id orelse return;

    const with_assistant = if (loop_messages) |messages| blk: {
        break :blk session.cloneMessagesAlloc(allocator, messages) catch |err| blk2: {
            logError("Session append failed for '{s}': {s}", .{ session_id, @errorName(err) });
            break :blk2 null;
        };
    } else session.appendAssistantMessageAlloc(
        allocator,
        base_messages,
        assistant_output,
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
            .session_id = allocator.dupe(u8, session_id) catch return,
            .tenant_id = if (parsed_req.tenant_id) |value| allocator.dupe(u8, value) catch return else null,
            .summary = if (loaded_session) |loaded| allocator.dupe(u8, loaded.summary) catch return else allocator.dupe(u8, "") catch return,
            .messages = session.trimToRetentionAlloc(
                allocator,
                messages,
                app_config.session_retention_messages,
            ) catch return,
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

fn sendApiErrorSafe(
    connection: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    api_error: backend.errors.ApiError,
    app_config: *const config.Config,
    request_id: ?[]const u8,
) void {
    response.sendApiError(connection, allocator, api_error, request_id) catch |err| {
        swallowSocketWriteError(app_config, err);
    };
}

fn sendJsonSafe(
    connection: std.net.Server.Connection,
    status_code: u16,
    body: []const u8,
    app_config: *const config.Config,
    request_id: ?[]const u8,
) void {
    if (request_id) |id| {
        response.sendJsonTextWithRequestId(connection, status_code, body, id) catch |err| {
            swallowSocketWriteError(app_config, err);
        };
    } else {
        response.sendJsonText(connection, status_code, body) catch |err| {
            swallowSocketWriteError(app_config, err);
        };
    }
}

fn sendChatCompletionSafe(
    connection: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    result: types.Response,
    app_config: *const config.Config,
    request_id: ?[]const u8,
) void {
    response.sendChatCompletion(connection, allocator, result, request_id) catch |err| {
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

test "connection gate recovers capacity after releases" {
    var gate = ConnectionGate{ .max_active = 1 };
    try std.testing.expect(gate.tryAcquire());
    try std.testing.expect(!gate.tryAcquire());

    gate.release();
    try std.testing.expect(gate.tryAcquire());
    gate.release();
    try std.testing.expect(gate.tryAcquire());
}

test "requiresAuth allows only health without an API key" {
    try std.testing.expect(!requiresAuth(.health));
    try std.testing.expect(requiresAuth(.metrics));
    try std.testing.expect(requiresAuth(.diagnostics_providers));
    try std.testing.expect(requiresAuth(.chat_completions));
}

test "server state tracks provider latency buckets" {
    var state = ServerState.init();
    defer state.deinit(std.testing.allocator);

    state.noteProviderLatency(10);
    state.noteProviderLatency(75);
    state.noteProviderLatency(500);
    state.noteProviderLatency(1500);

    const snapshot = state.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snapshot.provider_latency_buckets[0]);
    try std.testing.expectEqual(@as(u64, 1), snapshot.provider_latency_buckets[1]);
    try std.testing.expectEqual(@as(u64, 1), snapshot.provider_latency_buckets[2]);
    try std.testing.expectEqual(@as(u64, 1), snapshot.provider_latency_buckets[3]);
}

test "isLengthFinishReason detects provider length stops" {
    try std.testing.expect(isLengthFinishReason("length"));
    try std.testing.expect(isLengthFinishReason("LENGTH"));
    try std.testing.expect(!isLengthFinishReason("stop"));
}

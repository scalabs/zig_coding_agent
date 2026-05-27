//! Ollama-backed provider adapter for chat completion requests.
const std = @import("std");
const config = @import("../config.zig");
const types = @import("../types.zig");
const response = @import("../core/response.zig");

const ChatAttempt = struct {
    status: std.http.Status,
    body: []u8,

    fn deinit(self: ChatAttempt, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

const ModelFallback = struct {
    selected_model: []u8,
    suggested_model: ?[]u8,

    fn deinit(self: ModelFallback, allocator: std.mem.Allocator) void {
        allocator.free(self.selected_model);
        if (self.suggested_model) |model| allocator.free(model);
    }
};

const OllamaTuning = struct {
    think: bool,
    temperature: f64,
    repeat_penalty: f64,
    num_predict: u32,
};

const max_stream_continuations: usize = 4;

const stream_continue_prompt =
    "The previous assistant message was cut off by the generation limit. " ++
    "Continue the same answer from the exact next token. Output only the continuation text; " ++
    "do not mention truncation, continuation, the previous message, or these instructions.";

const OllamaStreamState = struct {
    saw_done: bool = false,
    stopped_by_length: bool = false,
    think_block_open: *bool,
};

const StreamAttempt = struct {
    saw_done: bool,
    stopped_by_length: bool,
};

const StreamAttemptResult = union(enum) {
    streamed: StreamAttempt,
    failed: types.Response,
};

pub const StreamQwenResult = union(enum) {
    streamed,
    failed: types.Response,
};

/// Per-turn streaming variant for use inside multi-turn loops (ReAct, agent).
///
/// Differences from `streamQwenToSse`:
/// - The caller owns SSE headers, the completion id, and the streaming buffers
///   (`captured_content`, `think_block_open`). Headers and `[DONE]` are NOT
///   emitted here.
/// - On success, returns the finish_reason and resolved model name in
///   `TurnStreamSuccess` so the loop can decide whether to continue, parse
///   actions, or stop.
/// - `captured_content` accumulates only the assistant `content` tokens (no
///   reasoning), giving the loop a clean buffer to feed back into the next
///   turn or hand to `react.parseReactAction`.
pub const TurnStreamSuccess = struct {
    finish_reason: []u8,
    model: []u8,

    pub fn deinit(self: TurnStreamSuccess, allocator: std.mem.Allocator) void {
        allocator.free(self.finish_reason);
        allocator.free(self.model);
    }
};

pub const TurnStreamResult = union(enum) {
    streamed: TurnStreamSuccess,
    failed: types.Response,
};

pub fn streamQwenTurnToSse(
    connection: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    request: types.Request,
    completion_id: []const u8,
    captured_content: *std.ArrayList(u8),
    think_block_open: *bool,
) !TurnStreamResult {
    const requested_model = request.model orelse app_config.ollama_model;
    var model_name = requested_model;
    var fallback: ?ModelFallback = null;
    defer if (fallback) |value| value.deinit(allocator);

    if (try pickFallbackModelAlloc(allocator, app_config, requested_model)) |selected| {
        fallback = selected;
        model_name = fallback.?.selected_model;
    }

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri_text = try buildChatUrl(allocator, app_config.ollama_base_url);
    defer allocator.free(uri_text);

    const uri = try std.Uri.parse(uri_text);

    var headers_sent_already = true; // caller already sent headers
    var final_finish_reason: []const u8 = "stop";

    var turn: usize = 0;
    while (true) : (turn += 1) {
        const messages_json = if (turn == 0)
            try renderMessagesJsonAlloc(allocator, request.messages)
        else
            try renderContinuationMessagesJsonAlloc(
                allocator,
                request.messages,
                captured_content.items,
                stream_continue_prompt,
            );
        defer allocator.free(messages_json);

        const attempt_result = try streamChatMessagesToSse(
            connection,
            allocator,
            &client,
            app_config,
            request,
            uri,
            completion_id,
            model_name,
            messages_json,
            &headers_sent_already,
            captured_content,
            think_block_open,
        );

        switch (attempt_result) {
            .failed => |failed_response| return .{ .failed = failed_response },
            .streamed => |attempt| {
                if (!attempt.stopped_by_length) break;
                if (turn + 1 >= max_stream_continuations) {
                    final_finish_reason = "length";
                    break;
                }
            },
        }
    }

    return .{ .streamed = .{
        .finish_reason = try allocator.dupe(u8, final_finish_reason),
        .model = try allocator.dupe(u8, model_name),
    } };
}

pub fn streamQwenToSse(
    connection: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    request: types.Request,
) !StreamQwenResult {
    const requested_model = request.model orelse app_config.ollama_model;
    var model_name = requested_model;
    var fallback: ?ModelFallback = null;
    defer if (fallback) |value| value.deinit(allocator);

    if (try pickFallbackModelAlloc(allocator, app_config, requested_model)) |selected| {
        fallback = selected;
        model_name = fallback.?.selected_model;

        const suggestion = fallback.?.suggested_model orelse fallback.?.selected_model;
        std.debug.print(
            "[warn] Ollama model '{s}' not installed. Using installed model '{s}'. Suggestion: set OLLAMA_MODEL='{s}'.\n",
            .{ requested_model, fallback.?.selected_model, suggestion },
        );
    }

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri_text = try buildChatUrl(allocator, app_config.ollama_base_url);
    defer allocator.free(uri_text);

    const uri = try std.Uri.parse(uri_text);

    const completion_id = try std.fmt.allocPrint(
        allocator,
        "chatcmpl-{d}",
        .{std.time.microTimestamp()},
    );
    defer allocator.free(completion_id);

    var headers_sent = false;
    var streamed_text = std.ArrayList(u8){};
    defer streamed_text.deinit(allocator);
    var final_finish_reason: []const u8 = "stop";
    var think_block_open: bool = false;

    var turn: usize = 0;
    while (true) : (turn += 1) {
        const messages_json = if (turn == 0)
            try renderMessagesJsonAlloc(allocator, request.messages)
        else
            try renderContinuationMessagesJsonAlloc(
                allocator,
                request.messages,
                streamed_text.items,
                stream_continue_prompt,
            );
        defer allocator.free(messages_json);

        const attempt_result = try streamChatMessagesToSse(
            connection,
            allocator,
            &client,
            app_config,
            request,
            uri,
            completion_id,
            model_name,
            messages_json,
            &headers_sent,
            &streamed_text,
            &think_block_open,
        );

        switch (attempt_result) {
            .failed => |failed_response| {
                if (!headers_sent) return .{ .failed = failed_response };
                defer failed_response.deinit(allocator);
                break;
            },
            .streamed => |attempt| {
                if (!attempt.stopped_by_length) break;
                if (turn + 1 >= max_stream_continuations) {
                    final_finish_reason = "length";
                    break;
                }
            },
        }
    }

    if (headers_sent) {
        if (think_block_open) {
            try response.sendChatCompletionChunkSse(
                connection, allocator, completion_id, model_name, "</think>", null,
            );
            think_block_open = false;
        }
        try response.sendChatCompletionChunkSse(
            connection,
            allocator,
            completion_id,
            model_name,
            null,
            final_finish_reason,
        );
        try response.sendSseDone(connection);
    } else {
        return .{ .failed = try makeResponse(allocator, model_name, "Ollama stream ended before headers were sent", false) };
    }

    return .streamed;
}

pub fn callQwen(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    request: types.Request,
) !types.Response {
    const requested_model = request.model orelse app_config.ollama_model;
    var model_name = requested_model;
    var fallback: ?ModelFallback = null;
    defer if (fallback) |value| value.deinit(allocator);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri_text = try buildChatUrl(allocator, app_config.ollama_base_url);
    defer allocator.free(uri_text);

    const uri = try std.Uri.parse(uri_text);

    const messages_json = try renderMessagesJsonAlloc(allocator, request.messages);
    defer allocator.free(messages_json);

    var attempt = try fetchChatAttemptAlloc(allocator, &client, app_config, request, uri, model_name, messages_json);
    defer attempt.deinit(allocator);

    if (attempt.status == .not_found) {
        const detail = try extractOllamaErrorAlloc(allocator, attempt.body);
        defer allocator.free(detail);

        if (isModelNotFound(detail)) {
            if (try pickFallbackModelAlloc(allocator, app_config, requested_model)) |selected| {
                fallback = selected;
                model_name = fallback.?.selected_model;

                const suggestion = fallback.?.suggested_model orelse fallback.?.selected_model;
                std.debug.print(
                    "[warn] Ollama model '{s}' not installed. Using installed model '{s}'. Suggestion: set OLLAMA_MODEL='{s}'.\n",
                    .{ requested_model, fallback.?.selected_model, suggestion },
                );

                attempt.deinit(allocator);
                attempt = try fetchChatAttemptAlloc(allocator, &client, app_config, request, uri, model_name, messages_json);
            }
        }
    }

    if (attempt.status != .ok) {
        const error_message = try buildHttpErrorMessageAlloc(allocator, attempt.status, attempt.body, model_name);
        defer allocator.free(error_message);
        return try makeResponse(allocator, model_name, error_message, false);
    }

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, attempt.body, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |value| value,
        else => return try makeResponse(
            allocator,
            model_name,
            "Invalid JSON from Ollama",
            false,
        ),
    };

    const message_value = root.get("message") orelse {
        return try makeResponse(
            allocator,
            model_name,
            "Missing message field from Ollama",
            false,
        );
    };

    const message_object = switch (message_value) {
        .object => |value| value,
        else => return try makeResponse(
            allocator,
            model_name,
            "Invalid message field from Ollama",
            false,
        ),
    };

    const content_value = switch (message_object.get("content") orelse {
        return try makeResponse(
            allocator,
            model_name,
            "Missing content field from Ollama message",
            false,
        );
    }) {
        .string => |value| value,
        else => return try makeResponse(
            allocator,
            model_name,
            "Invalid content field from Ollama message",
            false,
        ),
    };

    const thinking_value = if (message_object.get("thinking")) |thinking|
        switch (thinking) {
            .string => |value| value,
            else => "",
        }
    else
        "";

    const tuning = resolveTuning(app_config, request);
    const output = try formatAssistantOutputAlloc(allocator, content_value, thinking_value, tuning.think);
    errdefer allocator.free(output);

    // Ollama may omit done_reason; default to `stop` for OpenAI compatibility.
    const finish_reason = if (root.get("done_reason")) |done_reason|
        switch (done_reason) {
            .string => |value| value,
            else => "stop",
        }
    else
        "stop";

    return .{
        .id = null,
        .model = try allocator.dupe(u8, model_name),
        .output = output,
        .finish_reason = try allocator.dupe(u8, finish_reason),
        .success = true,
        .usage = .{
            .prompt_tokens = parseUsageField(root.get("prompt_eval_count")),
            .completion_tokens = parseUsageField(root.get("eval_count")),
            .total_tokens = parseUsageField(root.get("prompt_eval_count")) +
                parseUsageField(root.get("eval_count")),
        },
    };
}

fn formatAssistantOutputAlloc(
    allocator: std.mem.Allocator,
    content: []const u8,
    thinking: []const u8,
    include_thinking: bool,
) ![]u8 {
    if (!include_thinking or std.mem.trim(u8, thinking, " \t\r\n").len == 0) {
        return try allocator.dupe(u8, content);
    }

    if (std.mem.trim(u8, content, " \t\r\n").len == 0) {
        return try std.fmt.allocPrint(allocator, "<think>{s}</think>", .{thinking});
    }

    return try std.fmt.allocPrint(
        allocator,
        "<think>{s}</think>\n{s}",
        .{ thinking, content },
    );
}

test "formatAssistantOutputAlloc includes thinking when requested" {
    const allocator = std.testing.allocator;
    const output = try formatAssistantOutputAlloc(
        allocator,
        "final answer",
        "reasoning trace",
        true,
    );
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "<think>reasoning trace</think>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "final answer") != null);
}

test "formatAssistantOutputAlloc omits thinking when disabled" {
    const allocator = std.testing.allocator;
    const output = try formatAssistantOutputAlloc(
        allocator,
        "final answer",
        "reasoning trace",
        false,
    );
    defer allocator.free(output);

    try std.testing.expectEqualStrings("final answer", output);
}

pub fn buildStatusJsonAlloc(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
) ![]u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const tags_uri_text = try buildTagsUrl(allocator, app_config.ollama_base_url);
    defer allocator.free(tags_uri_text);

    const tags_uri = try std.Uri.parse(tags_uri_text);

    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    const result = client.fetch(.{
        .location = .{ .uri = tags_uri },
        .method = .GET,
        .response_writer = &writer.writer,
    }) catch |err| {
        return try formatStatusJsonAlloc(
            allocator,
            app_config.ollama_base_url,
            app_config.ollama_model,
            false,
            false,
            0,
            null,
            @errorName(err),
        );
    };

    const raw = writer.written();

    if (result.status != .ok) {
        const detail = try extractOllamaErrorAlloc(allocator, raw);
        defer allocator.free(detail);

        const status_detail = try std.fmt.allocPrint(
            allocator,
            "HTTP {s}: {s}",
            .{ @tagName(result.status), detail },
        );
        defer allocator.free(status_detail);

        return try formatStatusJsonAlloc(
            allocator,
            app_config.ollama_base_url,
            app_config.ollama_model,
            false,
            false,
            0,
            null,
            status_detail,
        );
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch |err| {
        return try formatStatusJsonAlloc(
            allocator,
            app_config.ollama_base_url,
            app_config.ollama_model,
            true,
            false,
            0,
            null,
            @errorName(err),
        );
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |value| value,
        else => {
            return try formatStatusJsonAlloc(
                allocator,
                app_config.ollama_base_url,
                app_config.ollama_model,
                true,
                false,
                0,
                null,
                "invalid_tags_payload",
            );
        },
    };

    const models_value = root.get("models") orelse {
        return try formatStatusJsonAlloc(
            allocator,
            app_config.ollama_base_url,
            app_config.ollama_model,
            true,
            false,
            0,
            null,
            "missing_models_field",
        );
    };

    const models = switch (models_value) {
        .array => |value| value,
        else => {
            return try formatStatusJsonAlloc(
                allocator,
                app_config.ollama_base_url,
                app_config.ollama_model,
                true,
                false,
                0,
                null,
                "invalid_models_field",
            );
        },
    };

    var configured_model_available = false;
    var first_model: ?[]const u8 = null;
    var related_model: ?[]const u8 = null;

    for (models.items) |model_value| {
        const model_obj = switch (model_value) {
            .object => |value| value,
            else => continue,
        };

        const name = switch (model_obj.get("name") orelse continue) {
            .string => |value| value,
            else => continue,
        };

        if (first_model == null) first_model = name;
        if (related_model == null and looksRelatedModel(name, app_config.ollama_model)) {
            related_model = name;
        }

        if (std.mem.eql(u8, name, app_config.ollama_model)) {
            configured_model_available = true;
        }
    }

    const suggested_model = related_model orelse first_model;

    const missing_model_error: ?[]const u8 = if (!configured_model_available)
        "configured_model_not_found"
    else
        null;

    return try formatStatusJsonAlloc(
        allocator,
        app_config.ollama_base_url,
        app_config.ollama_model,
        true,
        configured_model_available,
        models.items.len,
        suggested_model,
        missing_model_error,
    );
}

fn buildChatUrl(
    allocator: std.mem.Allocator,
    base_url: []const u8,
) ![]u8 {
    if (std.mem.endsWith(u8, base_url, "/")) {
        return try std.fmt.allocPrint(allocator, "{s}api/chat", .{base_url});
    }

    return try std.fmt.allocPrint(allocator, "{s}/api/chat", .{base_url});
}

fn buildTagsUrl(
    allocator: std.mem.Allocator,
    base_url: []const u8,
) ![]u8 {
    if (std.mem.endsWith(u8, base_url, "/")) {
        return try std.fmt.allocPrint(allocator, "{s}api/tags", .{base_url});
    }

    return try std.fmt.allocPrint(allocator, "{s}/api/tags", .{base_url});
}

fn streamChatMessagesToSse(
    connection: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    app_config: *const config.Config,
    request: types.Request,
    uri: std.Uri,
    completion_id: []const u8,
    model_name: []const u8,
    messages_json: []const u8,
    headers_sent: *bool,
    streamed_text: *std.ArrayList(u8),
    think_block_open: *bool,
) !StreamAttemptResult {
    const body = try buildChatPayloadAlloc(
        allocator,
        app_config,
        request,
        model_name,
        messages_json,
        true,
    );
    defer allocator.free(body);

    const headers = &[_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
    };

    var req = try client.request(.POST, uri, .{
        .extra_headers = headers,
        .keep_alive = false,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };

    var req_body = try req.sendBodyUnflushed(&.{});
    try req_body.writer.writeAll(body);
    try req_body.end();
    try req.connection.?.flush();

    var upstream = try req.receiveHead(&.{});

    if (upstream.head.status != .ok) {
        const error_message = try std.fmt.allocPrint(
            allocator,
            "Ollama HTTP {s} for model '{s}' during stream request",
            .{ @tagName(upstream.head.status), model_name },
        );
        defer allocator.free(error_message);

        return .{ .failed = try makeResponse(allocator, model_name, error_message, false) };
    }

    if (!headers_sent.*) {
        try response.sendEventStreamHeaders(connection);
        headers_sent.* = true;
    }

    var transfer_buffer: [2048]u8 = undefined;
    const body_reader = upstream.reader(transfer_buffer[0..]);

    var pending = std.ArrayList(u8){};
    defer pending.deinit(allocator);

    var read_buf: [1024]u8 = undefined;
    var state = OllamaStreamState{ .think_block_open = think_block_open };

    while (!state.saw_done) {
        const n = body_reader.readSliceShort(read_buf[0..]) catch |err| switch (err) {
            error.ReadFailed => return upstream.bodyErr() orelse err,
        };
        if (n == 0) break;

        try pending.appendSlice(allocator, read_buf[0..n]);
        try processPendingStreamLines(
            connection,
            allocator,
            completion_id,
            model_name,
            &pending,
            &state,
            streamed_text,
        );
    }

    if (pending.items.len > 0 and !state.saw_done) {
        const trailing = std.mem.trim(u8, pending.items, "\r\n \t");
        if (trailing.len > 0) {
            try handleOllamaStreamLine(
                connection,
                allocator,
                completion_id,
                model_name,
                trailing,
                &state,
                streamed_text,
            );
        }
    }

    return .{
        .streamed = .{
            .saw_done = state.saw_done,
            .stopped_by_length = state.stopped_by_length,
        },
    };
}

fn processPendingStreamLines(
    connection: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    completion_id: []const u8,
    fallback_model: []const u8,
    pending: *std.ArrayList(u8),
    state: *OllamaStreamState,
    streamed_text: *std.ArrayList(u8),
) !void {
    while (std.mem.indexOfScalar(u8, pending.items, '\n')) |line_end| {
        const raw_line = pending.items[0..line_end];
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len > 0) {
            try handleOllamaStreamLine(
                connection,
                allocator,
                completion_id,
                fallback_model,
                line,
                state,
                streamed_text,
            );
        }

        const next = line_end + 1;
        const remaining = pending.items.len - next;
        std.mem.copyForwards(u8, pending.items[0..remaining], pending.items[next..]);
        pending.items.len = remaining;
    }
}

fn handleOllamaStreamLine(
    connection: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    completion_id: []const u8,
    fallback_model: []const u8,
    line: []const u8,
    state: *OllamaStreamState,
    streamed_text: *std.ArrayList(u8),
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
        return;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |value| value,
        else => return,
    };

    const model = if (root.get("model")) |model_value|
        switch (model_value) {
            .string => |value| value,
            else => fallback_model,
        }
    else
        fallback_model;

    if (root.get("message")) |message_value| {
        const message_object = switch (message_value) {
            .object => |value| value,
            else => null,
        };

        if (message_object) |obj| {
            const thinking_text = if (obj.get("thinking")) |thinking_value|
                switch (thinking_value) {
                    .string => |value| value,
                    else => "",
                }
            else
                "";

            const content_text = if (obj.get("content")) |content_value|
                switch (content_value) {
                    .string => |value| value,
                    else => "",
                }
            else
                "";

            // Stream thinking wrapped in <think>...</think> tags so the client
            // can render it distinctly. Thinking is intentionally NOT appended
            // to streamed_text: that buffer feeds the "continue from cutoff"
            // prompt on length-stops, and including reasoning there causes the
            // model to restart its think block on every continuation.
            if (thinking_text.len > 0) {
                if (!state.think_block_open.*) {
                    try response.sendChatCompletionChunkSse(
                        connection, allocator, completion_id, model, "<think>", null,
                    );
                    state.think_block_open.* = true;
                }
                try response.sendChatCompletionChunkSse(
                    connection, allocator, completion_id, model, thinking_text, null,
                );
            }

            if (content_text.len > 0) {
                if (state.think_block_open.*) {
                    try response.sendChatCompletionChunkSse(
                        connection, allocator, completion_id, model, "</think>", null,
                    );
                    state.think_block_open.* = false;
                }
                try streamed_text.appendSlice(allocator, content_text);
                try response.sendChatCompletionChunkSse(
                    connection, allocator, completion_id, model, content_text, null,
                );
            }
        }
    }

    if (root.get("response")) |response_value| {
        const response_text = switch (response_value) {
            .string => |value| value,
            else => "",
        };

        if (response_text.len > 0) {
            try streamed_text.appendSlice(allocator, response_text);
            try response.sendChatCompletionChunkSse(
                connection,
                allocator,
                completion_id,
                model,
                response_text,
                null,
            );
        }
    }

    const done = if (root.get("done")) |done_value|
        switch (done_value) {
            .bool => |value| value,
            else => false,
        }
    else
        false;

    if (done and !state.saw_done) {
        const finish_reason = if (root.get("done_reason")) |reason_value|
            switch (reason_value) {
                .string => |value| value,
                else => "stop",
            }
        else
            "stop";

        state.saw_done = true;
        state.stopped_by_length = std.ascii.eqlIgnoreCase(finish_reason, "length");
    }
}

fn fetchChatAttemptAlloc(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    app_config: *const config.Config,
    request: types.Request,
    uri: std.Uri,
    model_name: []const u8,
    messages_json: []const u8,
) !ChatAttempt {
    const body = try buildChatPayloadAlloc(
        allocator,
        app_config,
        request,
        model_name,
        messages_json,
        false,
    );
    defer allocator.free(body);

    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    const headers = &[_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
    };

    const result = try client.fetch(.{
        .location = .{ .uri = uri },
        .method = .POST,
        .extra_headers = headers,
        .payload = body,
        .response_writer = &writer.writer,
    });

    return .{
        .status = result.status,
        .body = try allocator.dupe(u8, writer.written()),
    };
}

fn buildChatPayloadAlloc(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    request: types.Request,
    model_name: []const u8,
    messages_json: []const u8,
    stream: bool,
) ![]u8 {
    const tuning = resolveTuning(app_config, request);

    const tool_choice_json = if (request.tool_choice) |tool_choice| blk: {
        const escaped_tool_choice = try escapeJsonStringAlloc(allocator, tool_choice);
        defer allocator.free(escaped_tool_choice);
        break :blk try std.fmt.allocPrint(allocator, ",\"tool_choice\":\"{s}\"", .{escaped_tool_choice});
    } else try allocator.dupe(u8, "");
    defer allocator.free(tool_choice_json);

    const tools_json = if (request.tools.len > 0) blk: {
        const rendered_tools = try renderToolsJsonAlloc(allocator, request.tools);
        defer allocator.free(rendered_tools);
        break :blk try std.fmt.allocPrint(allocator, ",\"tools\":{s}", .{rendered_tools});
    } else try allocator.dupe(u8, "");
    defer allocator.free(tools_json);

    return try std.fmt.allocPrint(
        allocator,
        "{{\"model\":\"{s}\",\"messages\":{s},\"stream\":{},\"think\":{},\"options\":{{\"num_predict\":{d},\"temperature\":{d:.4},\"repeat_penalty\":{d:.4}}}{s}{s}}}",
        .{ model_name, messages_json, stream, tuning.think, tuning.num_predict, tuning.temperature, tuning.repeat_penalty, tools_json, tool_choice_json },
    );
}

fn renderToolsJsonAlloc(
    allocator: std.mem.Allocator,
    tools: []const types.Tool,
) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try out.append(allocator, '[');
    for (tools, 0..) |tool, index| {
        if (index > 0) try out.append(allocator, ',');

        const escaped_name = try escapeJsonStringAlloc(allocator, tool.name);
        defer allocator.free(escaped_name);
        const escaped_description = try escapeJsonStringAlloc(allocator, tool.description);
        defer allocator.free(escaped_description);

        try out.writer(allocator).print(
            "{{\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"description\":\"{s}\"}}}}",
            .{ escaped_name, escaped_description },
        );
    }
    try out.append(allocator, ']');
    return try out.toOwnedSlice(allocator);
}

fn resolveTuning(app_config: *const config.Config, request: types.Request) OllamaTuning {
    return .{
        .think = request.think orelse app_config.ollama_think,
        .temperature = request.temperature orelse app_config.ollama_temperature,
        .repeat_penalty = request.repeat_penalty orelse app_config.ollama_repeat_penalty,
        .num_predict = app_config.ollama_num_predict,
    };
}

fn pickFallbackModelAlloc(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    requested_model: []const u8,
) !?ModelFallback {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const tags_uri_text = try buildTagsUrl(allocator, app_config.ollama_base_url);
    defer allocator.free(tags_uri_text);

    const tags_uri = try std.Uri.parse(tags_uri_text);

    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    const result = client.fetch(.{
        .location = .{ .uri = tags_uri },
        .method = .GET,
        .response_writer = &writer.writer,
    }) catch {
        return null;
    };

    if (result.status != .ok) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, writer.written(), .{}) catch {
        return null;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |value| value,
        else => return null,
    };

    const models_value = root.get("models") orelse return null;
    const models = switch (models_value) {
        .array => |value| value,
        else => return null,
    };

    var first_model: ?[]const u8 = null;
    var related_model: ?[]const u8 = null;

    for (models.items) |model_value| {
        const model_obj = switch (model_value) {
            .object => |value| value,
            else => continue,
        };

        const name = switch (model_obj.get("name") orelse continue) {
            .string => |value| value,
            else => continue,
        };

        if (std.mem.eql(u8, name, requested_model)) {
            return null;
        }

        if (first_model == null) first_model = name;
        if (related_model == null and looksRelatedModel(name, requested_model)) {
            related_model = name;
        }
    }

    const selected_source = related_model orelse first_model orelse return null;
    const suggested_source = related_model orelse first_model;

    return .{
        .selected_model = try allocator.dupe(u8, selected_source),
        .suggested_model = if (suggested_source) |value| try allocator.dupe(u8, value) else null,
    };
}

fn looksRelatedModel(candidate: []const u8, requested: []const u8) bool {
    if (std.mem.eql(u8, candidate, requested)) return true;

    const requested_family = modelFamily(requested);
    if (requested_family.len == 0) return false;

    return startsWithIgnoreCase(candidate, requested_family);
}

fn modelFamily(model: []const u8) []const u8 {
    const separator = std.mem.indexOfScalar(u8, model, ':') orelse model.len;
    return model[0..separator];
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (prefix.len > value.len) return false;
    return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn isModelNotFound(detail: []const u8) bool {
    return std.mem.indexOf(u8, detail, "not found") != null;
}

fn escapeJsonStringAlloc(
    allocator: std.mem.Allocator,
    input: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn makeResponse(
    allocator: std.mem.Allocator,
    model: []const u8,
    output: []const u8,
    success: bool,
) !types.Response {
    return .{
        .id = null,
        .model = try allocator.dupe(u8, model),
        .output = try allocator.dupe(u8, output),
        .finish_reason = try allocator.dupe(u8, "stop"),
        .success = success,
        .usage = .{},
    };
}

fn renderMessagesJsonAlloc(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try out.append(allocator, '[');

    for (messages, 0..) |message, index| {
        if (index > 0) {
            try out.append(allocator, ',');
        }

        const escaped_role = try escapeJsonStringAlloc(allocator, message.role);
        defer allocator.free(escaped_role);

        const escaped_content = try escapeJsonStringAlloc(allocator, message.content);
        defer allocator.free(escaped_content);

        try out.writer(allocator).print(
            "{{\"role\":\"{s}\",\"content\":\"{s}\"}}",
            .{ escaped_role, escaped_content },
        );
    }

    try out.append(allocator, ']');
    return try out.toOwnedSlice(allocator);
}

fn renderContinuationMessagesJsonAlloc(
    allocator: std.mem.Allocator,
    base_messages: []const types.Message,
    assistant_content: []const u8,
    continue_prompt: []const u8,
) ![]u8 {
    const messages = try allocator.alloc(types.Message, base_messages.len + 2);
    defer allocator.free(messages);

    for (base_messages, 0..) |message, index| {
        messages[index] = message;
    }

    messages[base_messages.len] = .{
        .role = "assistant",
        .content = assistant_content,
    };
    messages[base_messages.len + 1] = .{
        .role = "user",
        .content = continue_prompt,
    };

    return try renderMessagesJsonAlloc(allocator, messages);
}

fn parseUsageField(value: ?std.json.Value) usize {
    const actual_value = value orelse return 0;

    return switch (actual_value) {
        .integer => |number| if (number < 0) 0 else @intCast(number),
        .float => |number| if (number < 0) 0 else @intFromFloat(number),
        else => 0,
    };
}

fn buildHttpErrorMessageAlloc(
    allocator: std.mem.Allocator,
    status: std.http.Status,
    raw_body: []const u8,
    model_name: []const u8,
) ![]u8 {
    const detail = try extractOllamaErrorAlloc(allocator, raw_body);
    defer allocator.free(detail);

    return try std.fmt.allocPrint(
        allocator,
        "Ollama HTTP {s} for model '{s}': {s}",
        .{ @tagName(status), model_name, detail },
    );
}

fn extractOllamaErrorAlloc(
    allocator: std.mem.Allocator,
    raw_body: []const u8,
) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_body, .{}) catch {
        return try allocator.dupe(u8, trimExcerpt(raw_body));
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |value| value,
        else => return try allocator.dupe(u8, trimExcerpt(raw_body)),
    };

    const error_field = root.get("error") orelse {
        return try allocator.dupe(u8, trimExcerpt(raw_body));
    };

    return switch (error_field) {
        .string => |value| try allocator.dupe(u8, value),
        else => try allocator.dupe(u8, trimExcerpt(raw_body)),
    };
}

fn trimExcerpt(raw_body: []const u8) []const u8 {
    if (raw_body.len == 0) return "<empty response body>";
    const max_len: usize = 240;
    if (raw_body.len <= max_len) return raw_body;
    return raw_body[0..max_len];
}

fn formatStatusJsonAlloc(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    configured_model: []const u8,
    reachable: bool,
    configured_model_available: bool,
    installed_model_count: usize,
    suggested_model: ?[]const u8,
    error_message: ?[]const u8,
) ![]u8 {
    const escaped_base_url = try escapeJsonStringAlloc(allocator, base_url);
    defer allocator.free(escaped_base_url);

    const escaped_configured_model = try escapeJsonStringAlloc(allocator, configured_model);
    defer allocator.free(escaped_configured_model);

    const suggested_json = try quoteOrNullAlloc(allocator, suggested_model);
    defer allocator.free(suggested_json);

    const error_json = try quoteOrNullAlloc(allocator, error_message);
    defer allocator.free(error_json);

    return try std.fmt.allocPrint(
        allocator,
        "{{\"provider\":\"ollama\",\"base_url\":\"{s}\",\"reachable\":{},\"configured_model\":\"{s}\",\"configured_model_available\":{},\"installed_model_count\":{d},\"suggested_model\":{s},\"error\":{s}}}",
        .{
            escaped_base_url,
            reachable,
            escaped_configured_model,
            configured_model_available,
            installed_model_count,
            suggested_json,
            error_json,
        },
    );
}

fn quoteOrNullAlloc(
    allocator: std.mem.Allocator,
    value: ?[]const u8,
) ![]u8 {
    if (value) |raw| {
        const escaped = try escapeJsonStringAlloc(allocator, raw);
        defer allocator.free(escaped);
        return try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
    }

    return try allocator.dupe(u8, "null");
}

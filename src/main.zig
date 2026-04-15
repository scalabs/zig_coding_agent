const std = @import("std");
const config = @import("config.zig");
const router = @import("router.zig");
const types = @import("types.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app_config = try config.Config.load(allocator);
    defer app_config.deinit(allocator);

    const address = try std.net.Address.parseIp(
        app_config.listen_host,
        app_config.listen_port,
    );

    var server = try address.listen(.{});
    defer server.deinit();

    std.debug.print(
        "Server running at http://{s}:{d}\n",
        .{ app_config.listen_host, app_config.listen_port },
    );
    std.debug.print("Default provider: {s}\n", .{app_config.default_provider.name()});
    if (app_config.debug_logging) {
        std.debug.print("Debug logging enabled\n", .{});
    }

    while (true) {
        var connection = try server.accept();
        defer connection.stream.close();

        handleConnection(allocator, &app_config, connection) catch |err| {
            std.debug.print("Request handling error: {}\n", .{err});
        };
    }
}

fn handleConnection(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    connection: std.net.Server.Connection,
) !void {
    const request_raw = readHttpRequest(allocator, connection) catch |err| switch (err) {
        error.RequestTooLarge => {
            try sendApiError(connection, allocator, .{
                .status_code = 413,
                .message = "Request body is too large",
                .error_type = "invalid_request_error",
                .param = null,
                .code = "request_too_large",
            });
            return;
        },
        error.HeadersTooLarge => {
            try sendApiError(connection, allocator, .{
                .status_code = 400,
                .message = "HTTP headers are too large",
                .error_type = "invalid_request_error",
                .param = null,
                .code = "headers_too_large",
            });
            return;
        },
        error.InvalidHttpRequest => {
            try sendApiError(connection, allocator, .{
                .status_code = 400,
                .message = "Malformed HTTP request",
                .error_type = "invalid_request_error",
                .param = null,
                .code = "invalid_http_request",
            });
            return;
        },
        error.MissingContentLength => {
            try sendApiError(connection, allocator, .{
                .status_code = 400,
                .message = "Missing Content-Length header",
                .error_type = "invalid_request_error",
                .param = null,
                .code = "missing_content_length",
            });
            return;
        },
        error.InvalidContentLength => {
            try sendApiError(connection, allocator, .{
                .status_code = 400,
                .message = "Invalid Content-Length header",
                .error_type = "invalid_request_error",
                .param = null,
                .code = "invalid_content_length",
            });
            return;
        },
        error.IncompleteRequestBody => {
            try sendApiError(connection, allocator, .{
                .status_code = 400,
                .message = "Incomplete request body",
                .error_type = "invalid_request_error",
                .param = null,
                .code = "incomplete_body",
            });
            return;
        },
        else => return err,
    };
    defer allocator.free(request_raw);

    if (request_raw.len == 0) return;

    debugLog(
        app_config,
        "request bytes={d} line={s}\n",
        .{ request_raw.len, firstRequestLine(request_raw) },
    );

    const is_chat_route = matchChatCompletionsRoute(request_raw) catch {
        try sendApiError(connection, allocator, .{
            .status_code = 400,
            .message = "Malformed HTTP request",
            .error_type = "invalid_request_error",
            .param = null,
            .code = "invalid_http_request",
        });
        return;
    };

    if (!is_chat_route) {
        try sendApiError(connection, allocator, .{
            .status_code = 404,
            .message = "Route not found",
            .error_type = "invalid_request_error",
            .param = null,
            .code = "not_found",
        });
        return;
    }

    const body = findBody(request_raw) orelse {
        try sendApiError(connection, allocator, .{
            .status_code = 400,
            .message = "Missing request body",
            .error_type = "invalid_request_error",
            .param = null,
            .code = "missing_body",
        });
        return;
    };

    debugLog(app_config, "request body_len={d}\n", .{body.len});

    const parse_result = try parseChatRequest(allocator, body);
    const req = switch (parse_result) {
        .ok => |request| request,
        .err => |api_error| {
            try sendApiError(connection, allocator, api_error);
            return;
        },
    };
    defer req.deinit(allocator);

    const selected_provider = req.provider orelse app_config.default_provider;
    const requested_model = req.model orelse "(default)";
    debugLog(
        app_config,
        "request provider={s} model={s} prompt_len={d} messages={d}\n",
        .{ selected_provider.name(), requested_model, req.prompt.len, req.messages.len },
    );

    const result = router.route(allocator, app_config, req) catch |err| {
        std.debug.print("Provider routing error: {}\n", .{err});
        try sendApiError(connection, allocator, providerApiError(
            "Provider request failed",
            "provider_request_failed",
        ));
        return;
    };
    defer result.deinit(allocator);

    if (!result.success) {
        debugLog(
            app_config,
            "provider error model={s} message_len={d}\n",
            .{ result.model, result.output.len },
        );
        try sendApiError(connection, allocator, providerApiError(
            result.output,
            "provider_error",
        ));
        return;
    }

    debugLog(
        app_config,
        "response model={s} finish_reason={s} usage_total={d}\n",
        .{ result.model, result.finish_reason, result.usage.total_tokens },
    );
    try sendChatCompletion(connection, allocator, result);
}

fn findBody(request_raw: []const u8) ?[]const u8 {
    const separator = "\r\n\r\n";
    const index = std.mem.indexOf(u8, request_raw, separator) orelse return null;
    return request_raw[index + separator.len ..];
}

fn firstRequestLine(request_raw: []const u8) []const u8 {
    const request_line_end = std.mem.indexOf(u8, request_raw, "\r\n") orelse request_raw.len;
    return request_raw[0..request_line_end];
}

fn readHttpRequest(
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
) ![]u8 {
    const max_request_size = 1024 * 1024;
    const max_header_size = 16 * 1024;

    var request = std.ArrayList(u8){};
    errdefer request.deinit(allocator);

    var chunk: [4096]u8 = undefined;
    var header_end: ?usize = null;
    var total_length: ?usize = null;

    while (true) {
        const bytes_read = try connection.stream.read(&chunk);
        if (bytes_read == 0) break;

        if (request.items.len + bytes_read > max_request_size) {
            return error.RequestTooLarge;
        }

        try request.appendSlice(allocator, chunk[0..bytes_read]);

        if (header_end == null) {
            if (std.mem.indexOf(u8, request.items, "\r\n\r\n")) |index| {
                header_end = index + 4;

                const content_length = try parseContentLength(request.items[0..index]);
                const required_length = header_end.? + content_length;
                if (required_length > max_request_size) {
                    return error.RequestTooLarge;
                }

                total_length = required_length;
            } else if (request.items.len > max_header_size) {
                return error.HeadersTooLarge;
            }
        }

        if (total_length) |required_length| {
            if (request.items.len >= required_length) break;
        }
    }

    if (request.items.len == 0) {
        return try allocator.alloc(u8, 0);
    }

    if (header_end == null or total_length == null) {
        return error.InvalidHttpRequest;
    }

    if (request.items.len < total_length.?) {
        return error.IncompleteRequestBody;
    }

    request.items.len = total_length.?;
    return try request.toOwnedSlice(allocator);
}

fn parseContentLength(headers: []const u8) !usize {
    var lines = std.mem.splitScalar(u8, headers, '\n');
    _ = lines.next() orelse return error.InvalidHttpRequest;

    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0) continue;

        const separator_index = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const header_name = std.mem.trim(u8, line[0..separator_index], " ");
        const header_value = std.mem.trim(u8, line[separator_index + 1 ..], " ");

        if (std.ascii.eqlIgnoreCase(header_name, "Content-Length")) {
            return std.fmt.parseInt(usize, header_value, 10) catch {
                return error.InvalidContentLength;
            };
        }
    }

    return error.MissingContentLength;
}

fn matchChatCompletionsRoute(request_raw: []const u8) !bool {
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

    return std.mem.eql(u8, method, "POST") and
        std.mem.eql(u8, target, "/v1/chat/completions");
}

const ApiError = struct {
    status_code: u16,
    message: []const u8,
    error_type: []const u8,
    param: ?[]const u8 = null,
    code: ?[]const u8 = null,
};

const ParseChatRequestResult = union(enum) {
    ok: types.Request,
    err: ApiError,
};

fn parseChatRequest(
    allocator: std.mem.Allocator,
    body: []const u8,
) !ParseChatRequestResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .err = validationError(
            "Request body must be valid JSON",
            null,
            "invalid_json",
        ) },
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |object| object,
        else => return .{ .err = validationError(
            "Request body must be a JSON object",
            null,
            "invalid_json",
        ) },
    };

    const provider = if (obj.get("provider")) |provider_value|
        switch (provider_value) {
            .string => |value| types.Provider.parse(value) orelse {
                return .{ .err = validationError(
                    "provider must be one of: ollama_qwen, openrouter, bedrock",
                    "provider",
                    "invalid_provider",
                ) };
            },
            else => return .{ .err = validationError(
                "provider must be a string",
                "provider",
                "invalid_provider",
            ) },
        }
    else
        null;

    const model_source = if (obj.get("model")) |model_value|
        switch (model_value) {
            .string => |value| blk: {
                if (value.len == 0) {
                    return .{ .err = validationError(
                        "model must not be empty",
                        "model",
                        "invalid_model",
                    ) };
                }

                if (std.ascii.eqlIgnoreCase(value, "auto")) {
                    break :blk null;
                }

                break :blk value;
            },
            else => return .{ .err = validationError(
                "model must be a string",
                "model",
                "invalid_model",
            ) },
        }
    else
        null;

    const parsed_messages = if (obj.get("messages")) |messages_value|
        switch (messages_value) {
            .array => |messages| blk: {
                if (messages.items.len == 0) {
                    return .{ .err = validationError(
                        "messages must not be empty",
                        "messages",
                        "invalid_messages",
                    ) };
                }

                var parsed_messages = std.ArrayList(types.Message){};
                errdefer {
                    for (parsed_messages.items) |message| {
                        message.deinit(allocator);
                    }
                    parsed_messages.deinit(allocator);
                }

                for (messages.items) |message_value| {
                    const message_obj = switch (message_value) {
                        .object => |object| object,
                        else => return .{ .err = validationError(
                            "Each message must be a JSON object",
                            "messages",
                            "invalid_messages",
                        ) },
                    };

                    const role = switch (message_obj.get("role") orelse {
                        return .{ .err = validationError(
                            "Each message must include a role",
                            "messages",
                            "invalid_messages",
                        ) };
                    }) {
                        .string => |value| value,
                        else => return .{ .err = validationError(
                            "message.role must be a string",
                            "messages",
                            "invalid_messages",
                        ) },
                    };

                    const content = switch (message_obj.get("content") orelse {
                        return .{ .err = validationError(
                            "Each message must include content",
                            "messages",
                            "invalid_messages",
                        ) };
                    }) {
                        .string => |value| value,
                        else => return .{ .err = validationError(
                            "message.content must be a string",
                            "messages",
                            "invalid_messages",
                        ) },
                    };

                    if (content.len == 0) {
                        return .{ .err = validationError(
                            "message.content must not be empty",
                            "messages",
                            "invalid_messages",
                        ) };
                    }

                    try parsed_messages.append(allocator, .{
                        .role = try allocator.dupe(u8, role),
                        .content = try allocator.dupe(u8, content),
                    });
                }

                if (!hasUserMessage(parsed_messages.items)) {
                    return .{ .err = validationError(
                        "messages must include at least one user message",
                        "messages",
                        "invalid_messages",
                    ) };
                }

                break :blk try parsed_messages.toOwnedSlice(allocator);
            },
            else => return .{ .err = validationError(
                "messages must be an array",
                "messages",
                "invalid_messages",
            ) },
        }
    else if (obj.get("prompt")) |prompt_value|
        switch (prompt_value) {
            .string => |value| blk: {
                if (value.len == 0) {
                    return .{ .err = validationError(
                        "prompt must not be empty",
                        "prompt",
                        "invalid_prompt",
                    ) };
                }

                var messages = try allocator.alloc(types.Message, 1);
                errdefer allocator.free(messages);

                messages[0] = .{
                    .role = try allocator.dupe(u8, "user"),
                    .content = try allocator.dupe(u8, value),
                };

                break :blk messages;
            },
            else => return .{ .err = validationError(
                "prompt must be a string",
                "prompt",
                "invalid_prompt",
            ) },
        }
    else
        return .{ .err = validationError(
            "Request must include a messages array or prompt string",
            null,
            "missing_input",
        ) };

    errdefer {
        for (parsed_messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(parsed_messages);
    }

    const prompt = try extractLastUserPrompt(allocator, parsed_messages);
    errdefer allocator.free(prompt);

    const model = if (model_source) |value| try allocator.dupe(u8, value) else null;
    errdefer if (model) |value| allocator.free(value);

    return .{ .ok = types.Request{
        .prompt = prompt,
        .messages = parsed_messages,
        .provider = provider,
        .model = model,
        .task = .chat,
    } };
}

fn hasUserMessage(messages: []const types.Message) bool {
    for (messages) |message| {
        if (std.ascii.eqlIgnoreCase(message.role, "user")) return true;
    }

    return false;
}

fn extractLastUserPrompt(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
) ![]u8 {
    var i: usize = messages.len;
    while (i > 0) {
        i -= 1;
        const message = messages[i];
        if (std.ascii.eqlIgnoreCase(message.role, "user")) {
            return try allocator.dupe(u8, message.content);
        }
    }

    return error.NoUserMessage;
}

fn validationError(
    message: []const u8,
    param: ?[]const u8,
    code: ?[]const u8,
) ApiError {
    return .{
        .status_code = 400,
        .message = message,
        .error_type = "invalid_request_error",
        .param = param,
        .code = code,
    };
}

fn providerApiError(
    message: []const u8,
    code: ?[]const u8,
) ApiError {
    return .{
        .status_code = 502,
        .message = message,
        .error_type = "provider_error",
        .param = null,
        .code = code,
    };
}

fn sendApiError(
    connection: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    api_error: ApiError,
) !void {
    const escaped_message = try escapeJsonStringAlloc(allocator, api_error.message);
    defer allocator.free(escaped_message);

    const param_json = try optionalJsonStringAlloc(allocator, api_error.param);
    defer allocator.free(param_json);

    const code_json = try optionalJsonStringAlloc(allocator, api_error.code);
    defer allocator.free(code_json);

    const response_json = try std.fmt.allocPrint(
        allocator,
        \\{{"error":{{"message":"{s}","type":"{s}","param":{s},"code":{s}}}}}
    , .{
        escaped_message,
        api_error.error_type,
        param_json,
        code_json,
    });
    defer allocator.free(response_json);

    try sendJson(connection, api_error.status_code, response_json);
}

fn sendChatCompletion(
    connection: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    result: types.Response,
) !void {
    var generated_id: ?[]u8 = null;
    defer if (generated_id) |id| allocator.free(id);

    const completion_id = if (result.id) |id|
        id
    else blk: {
        generated_id = try makeCompletionIdAlloc(allocator);
        break :blk generated_id.?;
    };

    const escaped_id = try escapeJsonStringAlloc(allocator, completion_id);
    defer allocator.free(escaped_id);

    const escaped_model = try escapeJsonStringAlloc(allocator, result.model);
    defer allocator.free(escaped_model);

    const escaped_content = try escapeJsonStringAlloc(allocator, result.output);
    defer allocator.free(escaped_content);

    const escaped_finish_reason = try escapeJsonStringAlloc(allocator, result.finish_reason);
    defer allocator.free(escaped_finish_reason);

    const response_json = try std.fmt.allocPrint(
        allocator,
        \\{{"id":"{s}","object":"chat.completion","created":{d},"model":"{s}","choices":[{{"index":0,"message":{{"role":"assistant","content":"{s}"}},"finish_reason":"{s}"}}],"usage":{{"prompt_tokens":{d},"completion_tokens":{d},"total_tokens":{d}}}}}
    , .{
        escaped_id,
        std.time.timestamp(),
        escaped_model,
        escaped_content,
        escaped_finish_reason,
        result.usage.prompt_tokens,
        result.usage.completion_tokens,
        result.usage.total_tokens,
    });
    defer allocator.free(response_json);

    try sendJson(connection, 200, response_json);
}

fn makeCompletionIdAlloc(allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "chatcmpl-{d}",
        .{std.time.microTimestamp()},
    );
}

fn debugLog(
    app_config: *const config.Config,
    comptime format: []const u8,
    args: anytype,
) void {
    if (!app_config.debug_logging) return;
    std.debug.print("[debug] " ++ format, args);
}

fn optionalJsonStringAlloc(
    allocator: std.mem.Allocator,
    value: ?[]const u8,
) ![]u8 {
    if (value) |text| {
        const escaped = try escapeJsonStringAlloc(allocator, text);
        defer allocator.free(escaped);

        return try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
    }

    return try allocator.dupe(u8, "null");
}

fn sendJson(
    connection: std.net.Server.Connection,
    status_code: u16,
    body: []const u8,
) !void {
    const status_text = switch (status_code) {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        413 => "Payload Too Large",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        else => "Internal Server Error",
    };

    const response = try std.fmt.allocPrint(
        std.heap.page_allocator,
        "HTTP/1.1 {d} {s}\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "{s}",
        .{ status_code, status_text, body.len, body },
    );
    defer std.heap.page_allocator.free(response);

    try connection.stream.writeAll(response);
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

test "parseChatRequest preserves messages and extracts last user prompt" {
    const allocator = std.testing.allocator;
    const body =
        \\{
        \\  "provider": "bedrock",
        \\  "model": "amazon.nova-micro-v1:0",
        \\  "messages": [
        \\    {"role": "system", "content": "You are concise."},
        \\    {"role": "user", "content": "First question"},
        \\    {"role": "assistant", "content": "First answer"},
        \\    {"role": "user", "content": "Second question"}
        \\  ]
        \\}
    ;

    const parsed = try parseChatRequest(allocator, body);
    const request = switch (parsed) {
        .ok => |request| request,
        .err => return error.UnexpectedApiError,
    };
    defer request.deinit(allocator);

    try std.testing.expectEqual(types.Provider.bedrock, request.provider.?);
    try std.testing.expectEqualStrings("amazon.nova-micro-v1:0", request.model.?);
    try std.testing.expectEqualStrings("Second question", request.prompt);
    try std.testing.expectEqual(@as(usize, 4), request.messages.len);
    try std.testing.expectEqualStrings("system", request.messages[0].role);
    try std.testing.expectEqualStrings("Second question", request.messages[3].content);
}

test "parseChatRequest treats model auto as default" {
    const allocator = std.testing.allocator;
    const body =
        \\{
        \\  "provider": "openrouter",
        \\  "model": "auto",
        \\  "messages": [
        \\    {"role": "user", "content": "Hello"}
        \\  ]
        \\}
    ;

    const parsed = try parseChatRequest(allocator, body);
    const request = switch (parsed) {
        .ok => |request| request,
        .err => return error.UnexpectedApiError,
    };
    defer request.deinit(allocator);

    try std.testing.expectEqual(types.Provider.openrouter, request.provider.?);
    try std.testing.expect(request.model == null);
    try std.testing.expectEqualStrings("Hello", request.prompt);
}

test "parseChatRequest rejects invalid provider" {
    const allocator = std.testing.allocator;
    const body =
        \\{
        \\  "provider": "bad-provider",
        \\  "messages": [
        \\    {"role": "user", "content": "Hello"}
        \\  ]
        \\}
    ;

    const parsed = try parseChatRequest(allocator, body);
    switch (parsed) {
        .ok => return error.ExpectedValidationError,
        .err => |api_error| {
            try std.testing.expectEqual(@as(u16, 400), api_error.status_code);
            try std.testing.expectEqualStrings("invalid_provider", api_error.code.?);
            try std.testing.expectEqualStrings("provider", api_error.param.?);
        },
    }
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

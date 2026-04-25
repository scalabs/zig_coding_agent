const std = @import("std");
const config = @import("../config.zig");
const types = @import("../types.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub fn callBedrock(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    request: types.Request,
) !types.Response {
    const model_name = request.model orelse app_config.bedrock_model;

    if (app_config.bedrock_access_key_id.len == 0 or app_config.bedrock_secret_access_key.len == 0) {
        return try errorResponse(
            allocator,
            model_name,
            "Bedrock provider selected but AWS credentials are not configured. Set AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY or BEDROCK_ACCESS_KEY_ID/BEDROCK_SECRET_ACCESS_KEY.",
        );
    }

    if (request.tools.len > 0 or request.tool_choice != null) {
        return try errorResponse(
            allocator,
            model_name,
            "Bedrock provider does not support tools yet.",
        );
    }

    const runtime_base_url = try resolveRuntimeBaseUrlAlloc(
        allocator,
        app_config.bedrock_runtime_base_url,
        app_config.bedrock_region,
    );
    defer allocator.free(runtime_base_url);

    const converse_url = try buildConverseUrlAlloc(allocator, runtime_base_url, model_name);
    defer allocator.free(converse_url);

    const uri = try std.Uri.parse(converse_url);

    const converse_body = renderConverseBodyAlloc(allocator, request.messages) catch |err| switch (err) {
        error.BedrockNoChatMessages => {
            return try errorResponse(
                allocator,
                model_name,
                "Bedrock requests must include at least one user or assistant message.",
            );
        },
        error.UnsupportedBedrockMessageRole => {
            return try errorResponse(
                allocator,
                model_name,
                "Bedrock supports only system, user, and assistant message roles.",
            );
        },
        else => return err,
    };
    defer allocator.free(converse_body);

    const signing = try buildSigV4HeadersAlloc(
        allocator,
        app_config,
        uri,
        converse_body,
    );
    defer signing.deinit(allocator);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var headers = std.ArrayList(std.http.Header){};
    defer headers.deinit(allocator);

    try headers.append(allocator, .{ .name = "content-type", .value = "application/json" });
    try headers.append(allocator, .{ .name = "host", .value = signing.host_header });
    try headers.append(allocator, .{ .name = "x-amz-date", .value = signing.amz_date });
    try headers.append(allocator, .{ .name = "x-amz-content-sha256", .value = signing.payload_hash });
    try headers.append(allocator, .{ .name = "authorization", .value = signing.authorization });

    if (signing.session_token) |session_token| {
        try headers.append(allocator, .{ .name = "x-amz-security-token", .value = session_token });
    }

    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    const result = try client.fetch(.{
        .location = .{ .uri = uri },
        .method = .POST,
        .extra_headers = headers.items,
        .payload = converse_body,
        .response_writer = &writer.writer,
    });

    return try parseBedrockResponse(
        allocator,
        model_name,
        result.status == .ok,
        writer.written(),
    );
}

pub fn buildStatusJsonAlloc(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
) ![]u8 {
    const runtime_base_url = try resolveRuntimeBaseUrlAlloc(
        allocator,
        app_config.bedrock_runtime_base_url,
        app_config.bedrock_region,
    );
    defer allocator.free(runtime_base_url);

    const escaped_base_url = try escapeJsonStringAlloc(allocator, runtime_base_url);
    defer allocator.free(escaped_base_url);

    const escaped_region = try escapeJsonStringAlloc(allocator, app_config.bedrock_region);
    defer allocator.free(escaped_region);

    const escaped_model = try escapeJsonStringAlloc(allocator, app_config.bedrock_model);
    defer allocator.free(escaped_model);

    return try std.fmt.allocPrint(
        allocator,
        "{{\"provider\":\"bedrock\",\"runtime_base_url\":\"{s}\",\"region\":\"{s}\",\"configured_credentials\":{},\"has_session_token\":{},\"default_model\":\"{s}\"}}",
        .{
            escaped_base_url,
            escaped_region,
            app_config.bedrock_access_key_id.len > 0 and app_config.bedrock_secret_access_key.len > 0,
            app_config.bedrock_session_token.len > 0,
            escaped_model,
        },
    );
}

fn resolveRuntimeBaseUrlAlloc(
    allocator: std.mem.Allocator,
    configured_base_url: []const u8,
    region: []const u8,
) ![]u8 {
    if (configured_base_url.len > 0) {
        return try allocator.dupe(u8, configured_base_url);
    }

    return try std.fmt.allocPrint(
        allocator,
        "https://bedrock-runtime.{s}.amazonaws.com",
        .{region},
    );
}

fn buildConverseUrlAlloc(
    allocator: std.mem.Allocator,
    runtime_base_url: []const u8,
    model_id: []const u8,
) ![]u8 {
    const encoded_model_id = try percentEncodePathSegmentAlloc(allocator, model_id);
    defer allocator.free(encoded_model_id);

    if (std.mem.endsWith(u8, runtime_base_url, "/")) {
        return try std.fmt.allocPrint(
            allocator,
            "{s}model/{s}/converse",
            .{ runtime_base_url, encoded_model_id },
        );
    }

    return try std.fmt.allocPrint(
        allocator,
        "{s}/model/{s}/converse",
        .{ runtime_base_url, encoded_model_id },
    );
}

const SigV4Headers = struct {
    host_header: []u8,
    amz_date: []u8,
    payload_hash: []u8,
    authorization: []u8,
    session_token: ?[]u8,

    fn deinit(self: *const SigV4Headers, allocator: std.mem.Allocator) void {
        allocator.free(self.host_header);
        allocator.free(self.amz_date);
        allocator.free(self.payload_hash);
        allocator.free(self.authorization);
        if (self.session_token) |session_token| {
            allocator.free(session_token);
        }
    }
};

fn buildSigV4HeadersAlloc(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    uri: std.Uri,
    payload: []const u8,
) !SigV4Headers {
    const host_header = try buildHostHeaderAlloc(allocator, uri);
    errdefer allocator.free(host_header);

    const timestamp = try buildAmzTimestamp();
    const amz_date = try allocator.dupe(u8, &timestamp.amz_date);
    errdefer allocator.free(amz_date);

    const payload_hash_buf = sha256Hex(payload);
    const payload_hash = try allocator.dupe(u8, &payload_hash_buf);
    errdefer allocator.free(payload_hash);

    const session_token = if (app_config.bedrock_session_token.len > 0)
        try allocator.dupe(u8, app_config.bedrock_session_token)
    else
        null;
    errdefer if (session_token) |value| allocator.free(value);

    const signed_headers = if (session_token != null)
        "content-type;host;x-amz-content-sha256;x-amz-date;x-amz-security-token"
    else
        "content-type;host;x-amz-content-sha256;x-amz-date";

    const canonical_uri = try canonicalizeSigV4PathAlloc(allocator, uri.path.percent_encoded);
    defer allocator.free(canonical_uri);

    const canonical_headers = if (session_token) |token|
        try std.fmt.allocPrint(
            allocator,
            "content-type:application/json\nhost:{s}\nx-amz-content-sha256:{s}\nx-amz-date:{s}\nx-amz-security-token:{s}\n",
            .{ host_header, payload_hash, amz_date, token },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "content-type:application/json\nhost:{s}\nx-amz-content-sha256:{s}\nx-amz-date:{s}\n",
            .{ host_header, payload_hash, amz_date },
        );
    defer allocator.free(canonical_headers);

    const canonical_request = try std.fmt.allocPrint(
        allocator,
        "POST\n{s}\n\n{s}\n{s}\n{s}",
        .{ canonical_uri, canonical_headers, signed_headers, payload_hash },
    );
    defer allocator.free(canonical_request);

    const canonical_request_hash_buf = sha256Hex(canonical_request);

    const credential_scope = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}/bedrock/aws4_request",
        .{ &timestamp.date_stamp, app_config.bedrock_region },
    );
    defer allocator.free(credential_scope);

    const string_to_sign = try std.fmt.allocPrint(
        allocator,
        "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}",
        .{ amz_date, credential_scope, &canonical_request_hash_buf },
    );
    defer allocator.free(string_to_sign);

    const signing_key = deriveSigningKey(
        app_config.bedrock_secret_access_key,
        &timestamp.date_stamp,
        app_config.bedrock_region,
        "bedrock",
    );

    const signature = hmacSha256(signing_key[0..], string_to_sign);
    const signature_hex = std.fmt.bytesToHex(signature, .lower);

    const authorization = try std.fmt.allocPrint(
        allocator,
        "AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders={s}, Signature={s}",
        .{ app_config.bedrock_access_key_id, credential_scope, signed_headers, &signature_hex },
    );
    errdefer allocator.free(authorization);

    return .{
        .host_header = host_header,
        .amz_date = amz_date,
        .payload_hash = payload_hash,
        .authorization = authorization,
        .session_token = session_token,
    };
}

fn buildHostHeaderAlloc(
    allocator: std.mem.Allocator,
    uri: std.Uri,
) ![]u8 {
    const host = uri.host orelse return error.InvalidUri;
    const host_value = host.percent_encoded;

    if (uri.port) |port| {
        const is_default_port =
            (std.mem.eql(u8, uri.scheme, "https") and port == 443) or
            (std.mem.eql(u8, uri.scheme, "http") and port == 80);

        if (!is_default_port) {
            return try std.fmt.allocPrint(allocator, "{s}:{d}", .{ host_value, port });
        }
    }

    return try allocator.dupe(u8, host_value);
}

fn canonicalizeSigV4PathAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    const actual_path = if (path.len == 0) "/" else path;

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    for (actual_path) |c| {
        if (c == '/') {
            try out.append(allocator, c);
            continue;
        }

        if (isUnreservedPathByte(c)) {
            try out.append(allocator, c);
            continue;
        }

        try out.writer(allocator).print("%{X:0>2}", .{c});
    }

    return try out.toOwnedSlice(allocator);
}

fn buildAmzTimestamp() !struct {
    amz_date: [16]u8,
    date_stamp: [8]u8,
} {
    const now = std.time.timestamp();
    if (now < 0) return error.InvalidSystemTime;

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(now) };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    var amz_date: [16]u8 = undefined;
    _ = try std.fmt.bufPrint(
        &amz_date,
        "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );

    var date_stamp: [8]u8 = undefined;
    _ = try std.fmt.bufPrint(
        &date_stamp,
        "{d:0>4}{d:0>2}{d:0>2}",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
        },
    );

    return .{
        .amz_date = amz_date,
        .date_stamp = date_stamp,
    };
}

fn sha256Hex(input: []const u8) [Sha256.digest_length * 2]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(input, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn hmacSha256(
    key: []const u8,
    message: []const u8,
) [HmacSha256.mac_length]u8 {
    var out: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&out, message, key);
    return out;
}

fn deriveSigningKey(
    secret_access_key: []const u8,
    date_stamp: []const u8,
    region: []const u8,
    service: []const u8,
) [HmacSha256.mac_length]u8 {
    var secret_prefix: [4 + 256]u8 = undefined;
    if (secret_access_key.len > 256) @panic("AWS secret access key too long");

    @memcpy(secret_prefix[0..4], "AWS4");
    @memcpy(secret_prefix[4 .. 4 + secret_access_key.len], secret_access_key);
    const secret = secret_prefix[0 .. 4 + secret_access_key.len];

    const date_key = hmacSha256(secret, date_stamp);
    const region_key = hmacSha256(date_key[0..], region);
    const service_key = hmacSha256(region_key[0..], service);
    return hmacSha256(service_key[0..], "aws4_request");
}

fn parseBedrockResponse(
    allocator: std.mem.Allocator,
    fallback_model: []const u8,
    is_http_ok: bool,
    raw: []const u8,
) !types.Response {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
        if (is_http_ok) {
            return try errorResponse(
                allocator,
                fallback_model,
                "Bedrock returned invalid JSON",
            );
        }

        return try errorResponse(
            allocator,
            fallback_model,
            "Bedrock returned a non-JSON error response",
        );
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return try errorResponse(
            allocator,
            fallback_model,
            "Bedrock returned an invalid response object",
        ),
    };

    if (extractBedrockErrorMessage(root)) |message| {
        return try errorResponse(allocator, fallback_model, message);
    }

    if (!is_http_ok) {
        return try errorResponse(
            allocator,
            fallback_model,
            "Bedrock request failed",
        );
    }

    const output_object = switch (root.get("output") orelse {
        return try errorResponse(allocator, fallback_model, "Bedrock response is missing output");
    }) {
        .object => |value| value,
        else => return try errorResponse(allocator, fallback_model, "Bedrock output is invalid"),
    };

    const message_object = switch (output_object.get("message") orelse {
        return try errorResponse(allocator, fallback_model, "Bedrock response is missing output message");
    }) {
        .object => |value| value,
        else => return try errorResponse(allocator, fallback_model, "Bedrock output message is invalid"),
    };

    const content_array = switch (message_object.get("content") orelse {
        return try errorResponse(allocator, fallback_model, "Bedrock output content is missing");
    }) {
        .array => |value| value,
        else => return try errorResponse(allocator, fallback_model, "Bedrock output content is invalid"),
    };

    const content_text = extractBedrockTextAlloc(allocator, content_array.items) catch |err| switch (err) {
        error.BedrockTextContentMissing => {
            return try errorResponse(
                allocator,
                fallback_model,
                "Bedrock output did not include any text content.",
            );
        },
        else => return err,
    };
    defer allocator.free(content_text);

    const stop_reason = if (root.get("stopReason")) |stop_reason_value|
        switch (stop_reason_value) {
            .string => |value| value,
            else => "stop",
        }
    else
        "stop";

    return .{
        .id = null,
        .model = try allocator.dupe(u8, fallback_model),
        .output = try allocator.dupe(u8, content_text),
        .finish_reason = try allocator.dupe(u8, stop_reason),
        .success = true,
        .usage = extractBedrockUsage(root),
    };
}

fn extractBedrockErrorMessage(root: std.json.ObjectMap) ?[]const u8 {
    if (root.get("message")) |message_value| {
        switch (message_value) {
            .string => |message| return message,
            else => {},
        }
    }

    if (root.get("error")) |error_value| {
        switch (error_value) {
            .object => |error_object| {
                if (error_object.get("message")) |message_value| {
                    return switch (message_value) {
                        .string => |message| message,
                        else => null,
                    };
                }
            },
            .string => |message| return message,
            else => {},
        }
    }

    return null;
}

fn extractBedrockTextAlloc(
    allocator: std.mem.Allocator,
    content_items: []const std.json.Value,
) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    for (content_items) |content_item| {
        const content_object = switch (content_item) {
            .object => |value| value,
            else => continue,
        };

        const text_value = switch (content_object.get("text") orelse continue) {
            .string => |value| value,
            else => continue,
        };

        try out.appendSlice(allocator, text_value);
    }

    if (out.items.len == 0) {
        return error.BedrockTextContentMissing;
    }

    return try out.toOwnedSlice(allocator);
}

fn extractBedrockUsage(root: std.json.ObjectMap) types.Usage {
    const usage_value = root.get("usage") orelse return .{};

    const usage_object = switch (usage_value) {
        .object => |value| value,
        else => return .{},
    };

    return .{
        .prompt_tokens = parseUsageField(usage_object.get("inputTokens")),
        .completion_tokens = parseUsageField(usage_object.get("outputTokens")),
        .total_tokens = parseUsageField(usage_object.get("totalTokens")),
    };
}

fn parseUsageField(value: ?std.json.Value) usize {
    const actual_value = value orelse return 0;

    return switch (actual_value) {
        .integer => |number| if (number < 0) 0 else @intCast(number),
        .float => |number| if (number < 0) 0 else @intFromFloat(number),
        else => 0,
    };
}

fn renderConverseBodyAlloc(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
) ![]u8 {
    var system_json = std.ArrayList(u8){};
    defer system_json.deinit(allocator);

    var chat_json = std.ArrayList(u8){};
    defer chat_json.deinit(allocator);

    var has_system = false;
    var has_chat_messages = false;

    try system_json.append(allocator, '[');
    try chat_json.append(allocator, '[');

    for (messages) |message| {
        if (std.ascii.eqlIgnoreCase(message.role, "system")) {
            if (has_system) {
                try system_json.append(allocator, ',');
            }

            const escaped_content = try escapeJsonStringAlloc(allocator, message.content);
            defer allocator.free(escaped_content);

            try system_json.writer(allocator).print(
                "{{\"text\":\"{s}\"}}",
                .{escaped_content},
            );
            has_system = true;
            continue;
        }

        if (!std.ascii.eqlIgnoreCase(message.role, "user") and !std.ascii.eqlIgnoreCase(message.role, "assistant")) {
            return error.UnsupportedBedrockMessageRole;
        }

        if (has_chat_messages) {
            try chat_json.append(allocator, ',');
        }

        const escaped_role = try escapeJsonStringAlloc(allocator, message.role);
        defer allocator.free(escaped_role);

        const escaped_content = try escapeJsonStringAlloc(allocator, message.content);
        defer allocator.free(escaped_content);

        try chat_json.writer(allocator).print(
            "{{\"role\":\"{s}\",\"content\":[{{\"text\":\"{s}\"}}]}}",
            .{ escaped_role, escaped_content },
        );
        has_chat_messages = true;
    }

    try system_json.append(allocator, ']');
    try chat_json.append(allocator, ']');

    if (!has_chat_messages) {
        return error.BedrockNoChatMessages;
    }

    if (has_system) {
        return try std.fmt.allocPrint(
            allocator,
            "{{\"messages\":{s},\"system\":{s}}}",
            .{ chat_json.items, system_json.items },
        );
    }

    return try std.fmt.allocPrint(
        allocator,
        "{{\"messages\":{s}}}",
        .{chat_json.items},
    );
}

fn percentEncodePathSegmentAlloc(
    allocator: std.mem.Allocator,
    input: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    for (input) |c| {
        if (isUnreservedPathByte(c)) {
            try out.append(allocator, c);
        } else {
            try out.writer(allocator).print("%{X:0>2}", .{c});
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn isUnreservedPathByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

fn errorResponse(
    allocator: std.mem.Allocator,
    model: []const u8,
    message: []const u8,
) !types.Response {
    return .{
        .id = null,
        .model = try allocator.dupe(u8, model),
        .output = try allocator.dupe(u8, message),
        .finish_reason = try allocator.dupe(u8, "error"),
        .success = false,
        .usage = .{},
    };
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

test "resolveRuntimeBaseUrlAlloc prefers explicit base url" {
    const allocator = std.testing.allocator;
    const value = try resolveRuntimeBaseUrlAlloc(allocator, "https://example.com/custom", "us-east-1");
    defer allocator.free(value);

    try std.testing.expectEqualStrings("https://example.com/custom", value);
}

test "resolveRuntimeBaseUrlAlloc falls back to regional runtime url" {
    const allocator = std.testing.allocator;
    const value = try resolveRuntimeBaseUrlAlloc(allocator, "", "ap-southeast-2");
    defer allocator.free(value);

    try std.testing.expectEqualStrings("https://bedrock-runtime.ap-southeast-2.amazonaws.com", value);
}

test "buildConverseUrlAlloc percent-encodes model ids" {
    const allocator = std.testing.allocator;
    const url = try buildConverseUrlAlloc(
        allocator,
        "https://bedrock-runtime.us-east-1.amazonaws.com",
        "amazon.nova-micro-v1:0",
    );
    defer allocator.free(url);

    try std.testing.expectEqualStrings(
        "https://bedrock-runtime.us-east-1.amazonaws.com/model/amazon.nova-micro-v1%3A0/converse",
        url,
    );
}

test "renderConverseBodyAlloc rejects unsupported Bedrock roles" {
    const allocator = std.testing.allocator;
    const messages = try allocator.alloc(types.Message, 1);
    defer {
        for (messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(messages);
    }

    messages[0] = .{
        .role = try allocator.dupe(u8, "tool"),
        .content = try allocator.dupe(u8, "unsupported"),
    };

    try std.testing.expectError(
        error.UnsupportedBedrockMessageRole,
        renderConverseBodyAlloc(allocator, messages),
    );
}

test "parseBedrockResponse extracts text and usage" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"output":{"message":{"content":[{"text":"Hello"},{"text":" world"}]}},"stopReason":"end_turn","usage":{"inputTokens":5,"outputTokens":7,"totalTokens":12}}
    ;

    const response = try parseBedrockResponse(
        allocator,
        "amazon.nova-micro-v1:0",
        true,
        raw,
    );
    defer response.deinit(allocator);

    try std.testing.expect(response.success);
    try std.testing.expectEqualStrings("Hello world", response.output);
    try std.testing.expectEqualStrings("end_turn", response.finish_reason);
    try std.testing.expectEqual(@as(usize, 12), response.usage.total_tokens);
}

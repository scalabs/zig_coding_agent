const std = @import("std");
const types = @import("types.zig");

const BACKEND_HOST = "127.0.0.1";
const BACKEND_PORT = 8081;

pub fn providerToString(provider: types.Provider) []const u8 {
    return switch (provider) {
        .ollama => "Ollama",
        .openai => "OpenAI",
        .openrouter => "OpenRouter",
        .claude => "Claude",
        .bedrock => "Bedrock",
        .llama_cpp => "llama.cpp",
    };
}

pub fn providerToRaw(provider: types.Provider) []const u8 {
    return switch (provider) {
        .ollama => "ollama",
        .openai => "openai",
        .openrouter => "openrouter",
        .claude => "claude",
        .bedrock => "bedrock",
        .llama_cpp => "llama_cpp",
    };
}

pub fn modeToString(mode: types.LoopMode) []const u8 {
    return switch (mode) {
        .basic => "Basic",
        .agent => "Agent",
        .react => "ReAct",
    };
}

pub fn modeToRaw(mode: types.LoopMode) []const u8 {
    return switch (mode) {
        .basic => "basic",
        .agent => "agent",
        .react => "react",
    };
}

pub fn checkBackendHealth(allocator: std.mem.Allocator) ![]u8 {
    const response = try sendGetRequest(allocator, "/health");
    defer allocator.free(response);

    return try allocator.dupe(u8, responseBody(response));
}

pub fn getProviderDiagnostics(allocator: std.mem.Allocator) ![]u8 {
    const response = try sendGetRequest(allocator, "/diagnostics/providers");
    defer allocator.free(response);

    return try allocator.dupe(u8, responseBody(response));
}

pub fn runBackend(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    provider: types.Provider,
    mode: types.LoopMode,
    session_label: []const u8,
) !void {
    std.debug.print("\n==============================\n", .{});
    std.debug.print("Calling backend API...\n", .{});
    std.debug.print("Endpoint: http://{s}:{d}/v1/chat/completions\n", .{ BACKEND_HOST, BACKEND_PORT });
    std.debug.print("Provider: {s}\n", .{providerToString(provider)});
    std.debug.print("Mode: {s}\n", .{modeToString(mode)});
    if (session_label.len > 0) {
        std.debug.print("Session: {s}\n", .{session_label});
    }
    std.debug.print("Status: Sending request...\n", .{});
    std.debug.print("Waiting for model response. Local Ollama models may take a few seconds...\n", .{});
    const body = try buildChatRequestJson(
        allocator,
        prompt,
        providerToRaw(provider),
        modeToRaw(mode),
        session_label,
    );
    defer allocator.free(body);

    const response = try sendPostRequest(allocator, "/v1/chat/completions", body);
    defer allocator.free(response);

    printChatResponse(responseBody(response));
	
}

fn buildChatRequestJson(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    provider: []const u8,
    mode: []const u8,
    session_label: []const u8,
) ![]u8 {
    const escaped_prompt = try escapeJsonStringAlloc(allocator, prompt);
    defer allocator.free(escaped_prompt);

    if (session_label.len > 0) {
        const escaped_session = try escapeJsonStringAlloc(allocator, session_label);
        defer allocator.free(escaped_session);

        return try std.fmt.allocPrint(
            allocator,
            "{{\"provider\":\"{s}\",\"prompt\":\"{s}\",\"loop_mode\":\"{s}\",\"session_id\":\"{s}\"}}",
            .{ provider, escaped_prompt, mode, escaped_session },
        );
    }

    return try std.fmt.allocPrint(
        allocator,
        "{{\"provider\":\"{s}\",\"prompt\":\"{s}\",\"loop_mode\":\"{s}\"}}",
        .{ provider, escaped_prompt, mode },
    );
}

fn sendGetRequest(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const address = try std.net.Address.parseIp(BACKEND_HOST, BACKEND_PORT);
    const stream = try std.net.tcpConnectToAddress(address);
    defer stream.close();

    const request = try std.fmt.allocPrint(
        allocator,
        "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n",
        .{ path, BACKEND_HOST, BACKEND_PORT },
    );
    defer allocator.free(request);

    try stream.writeAll(request);
    return try readAllAlloc(allocator, stream);
}

fn sendPostRequest(allocator: std.mem.Allocator, path: []const u8, body: []const u8) ![]u8 {
    const address = try std.net.Address.parseIp(BACKEND_HOST, BACKEND_PORT);
    const stream = try std.net.tcpConnectToAddress(address);
    defer stream.close();

    const request = try std.fmt.allocPrint(
        allocator,
        "POST {s} HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ path, BACKEND_HOST, BACKEND_PORT, body.len, body },
    );
    defer allocator.free(request);

    try stream.writeAll(request);
    return try readAllAlloc(allocator, stream);
}

fn readAllAlloc(allocator: std.mem.Allocator, stream: std.net.Stream) ![]u8 {
    var output = std.ArrayList(u8){};
    defer output.deinit(allocator);

    var buffer: [4096]u8 = undefined;
    while (true) {
        const n = try stream.read(&buffer);
        if (n == 0) break;
        try output.appendSlice(allocator, buffer[0..n]);
    }

    return try output.toOwnedSlice(allocator);
}

fn responseBody(response: []const u8) []const u8 {
    const separator = "\r\n\r\n";
    const index = std.mem.indexOf(u8, response, separator) orelse return response;
    return response[index + separator.len ..];
}

fn escapeJsonStringAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output = std.ArrayList(u8){};
    defer output.deinit(allocator);

    for (input) |char| {
        switch (char) {
            '"' => try output.appendSlice(allocator, "\\\""),
            '\\' => try output.appendSlice(allocator, "\\\\"),
            '\n' => try output.appendSlice(allocator, "\\n"),
            '\r' => try output.appendSlice(allocator, "\\r"),
            '\t' => try output.appendSlice(allocator, "\\t"),
            else => try output.append(allocator, char),
        }
    }

    return try output.toOwnedSlice(allocator);
}

fn printChatResponse(json: []const u8) void {
    if (std.mem.indexOf(u8, json, "\"error\"") != null) {
        std.debug.print("\nBackend Error:\n{s}\n", .{json});
        return;
    }

    std.debug.print("\nAssistant Response\n", .{});
    std.debug.print("--------------------------------------\n", .{});

    if (extractJsonStringValue(json, "content")) |content| {
        printUnescapedText(content);
        } 
    else {
        std.debug.print("{s}\n", .{json});
}

    std.debug.print("\nMetadata\n", .{});
    std.debug.print("--------------------------------------\n", .{});

    if (extractJsonStringValue(json, "model")) |model| {
        std.debug.print("Model: {s}\n", .{model});
    }

    if (extractJsonStringValue(json, "finish_reason")) |finish_reason| {
    std.debug.print("Finish reason: {s}\n", .{finish_reason});

    if (std.mem.eql(u8, finish_reason, "length")) {
        std.debug.print(
            "Warning: response truncated due to token limit.\n",
            .{},
        );
    }
}

    if (extractJsonNumberValue(json, "total_tokens")) |tokens| {
        std.debug.print("Total tokens: {s}\n", .{tokens});
    }
}

fn printUnescapedText(text: []const u8) void {
    var i: usize = 0;

    while (i < text.len) : (i += 1) {
        if (text[i] == '\\' and i + 1 < text.len) {
            switch (text[i + 1]) {
                'n' => {
                    std.debug.print("\n", .{});
                    i += 1;
                    continue;
                },
                't' => {
                    std.debug.print("\t", .{});
                    i += 1;
                    continue;
                },
                'r' => {
                    i += 1;
                    continue;
                },
                '\\' => {
                    std.debug.print("\\", .{});
                    i += 1;
                    continue;
                },
                '"' => {
                    std.debug.print("\"", .{});
                    i += 1;
                    continue;
                },
                else => {},
            }
        }

        std.debug.print("{c}", .{text[i]});
    }

    std.debug.print("\n", .{});
}

fn extractJsonStringValue(json: []const u8, key: []const u8) ?[]const u8 {
    var pattern_buf: [128]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\":\"", .{key}) catch return null;

    const start = std.mem.indexOf(u8, json, pattern) orelse return null;
    const value_start = start + pattern.len;
    const rest = json[value_start..];
    const value_end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;

    return rest[0..value_end];
}

fn extractJsonNumberValue(json: []const u8, key: []const u8) ?[]const u8 {
    var pattern_buf: [128]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\":", .{key}) catch return null;

    const start = std.mem.indexOf(u8, json, pattern) orelse return null;
    const value_start = start + pattern.len;
    const rest = json[value_start..];

    var end: usize = 0;
    while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') {
        end += 1;
    }

    if (end == 0) return null;
    return rest[0..end];
}

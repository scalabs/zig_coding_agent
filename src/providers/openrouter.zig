const std = @import("std");
const config = @import("../config.zig");
const types = @import("../types.zig");
const openai_compatible = @import("openai_compatible.zig");

pub fn callOpenRouter(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    request: types.Request,
) !types.Response {
    if (app_config.openrouter_api_key.len == 0) {
        return try errorResponse(
            allocator,
            request.model orelse app_config.openrouter_model,
            "OpenRouter provider selected but OPENROUTER_API_KEY is not set",
        );
    }

    const model_name = request.model orelse app_config.openrouter_model;
    var extra_headers_buffer: [2]std.http.Header = undefined;
    const extra_headers = buildExtraHeaders(
        app_config.openrouter_http_referer,
        app_config.openrouter_app_name,
        &extra_headers_buffer,
    );

    return try openai_compatible.callChatWithExtraHeaders(
        allocator,
        app_config.openrouter_base_url,
        app_config.openrouter_api_key,
        model_name,
        request,
        "OpenRouter",
        extra_headers,
    );
}

pub fn buildStatusJsonAlloc(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
) ![]u8 {
    const escaped_base_url = try escapeJsonStringAlloc(allocator, app_config.openrouter_base_url);
    defer allocator.free(escaped_base_url);

    const escaped_model = try escapeJsonStringAlloc(allocator, app_config.openrouter_model);
    defer allocator.free(escaped_model);

    return try std.fmt.allocPrint(
        allocator,
        "{{\"provider\":\"openrouter\",\"base_url\":\"{s}\",\"configured_api_key\":{},\"default_model\":\"{s}\",\"has_http_referer\":{},\"has_app_name\":{}}}",
        .{
            escaped_base_url,
            app_config.openrouter_api_key.len > 0,
            escaped_model,
            app_config.openrouter_http_referer.len > 0,
            app_config.openrouter_app_name.len > 0,
        },
    );
}

fn buildExtraHeaders(
    http_referer: []const u8,
    app_name: []const u8,
    buffer: *[2]std.http.Header,
) []const std.http.Header {
    var len: usize = 0;

    if (http_referer.len > 0) {
        buffer[len] = .{
            .name = "http-referer",
            .value = http_referer,
        };
        len += 1;
    }

    if (app_name.len > 0) {
        buffer[len] = .{
            .name = "x-openrouter-title",
            .value = app_name,
        };
        len += 1;
    }

    return buffer[0..len];
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
        .finish_reason = try allocator.dupe(u8, "stop"),
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

test "buildExtraHeaders includes configured OpenRouter headers" {
    var buffer: [2]std.http.Header = undefined;
    const headers = buildExtraHeaders("https://example.com", "Zig Router", &buffer);

    try std.testing.expectEqual(@as(usize, 2), headers.len);
    try std.testing.expectEqualStrings("http-referer", headers[0].name);
    try std.testing.expectEqualStrings("https://example.com", headers[0].value);
    try std.testing.expectEqualStrings("x-openrouter-title", headers[1].name);
    try std.testing.expectEqualStrings("Zig Router", headers[1].value);
}

test "buildExtraHeaders omits empty OpenRouter headers" {
    var buffer: [2]std.http.Header = undefined;
    const headers = buildExtraHeaders("", "", &buffer);

    try std.testing.expectEqual(@as(usize, 0), headers.len);
}

//! OpenAI provider adapter.
//!
//! Thin wrapper around `openai_compatible.callChat` that injects
//! the OpenAI base URL and API key from configuration.

const std = @import("std");

/// Delegates to `openai_compatible.callChat` with OpenAI credentials.
/// Returns an error response if the API key is not configured.
pub fn callOpenAI(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    request: types.Request,
) !types.Response {
    if (app_config.openai_api_key.len == 0) {
        return .{
            .id = null,
            .model = try allocator.dupe(u8, request.model orelse app_config.openai_model),
            .output = try allocator.dupe(u8, "OpenAI API key is not configured on the server"),
            .finish_reason = try allocator.dupe(u8, "stop"),
            .success = false,
            .usage = .{},
        };
    }

    const model_name = request.model orelse app_config.openai_model;
    return try openai_compatible.callChat(
        allocator,
        app_config.openai_base_url,
        app_config.openai_api_key,
        model_name,
        request,
        "OpenAI",
    );
}

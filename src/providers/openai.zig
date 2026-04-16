const std = @import("std");
const config = @import("../config.zig");
const types = @import("../types.zig");
const openai_compatible = @import("openai_compatible.zig");

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

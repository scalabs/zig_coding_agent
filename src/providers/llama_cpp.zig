const std = @import("std");
const config = @import("../config.zig");
const types = @import("../types.zig");
const openai_compatible = @import("openai_compatible.zig");

pub fn callLlamaCpp(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    request: types.Request,
) !types.Response {
    const model_name = request.model orelse app_config.llama_cpp_model;

    const maybe_key: ?[]const u8 = if (app_config.llama_cpp_api_key.len > 0)
        app_config.llama_cpp_api_key
    else
        null;

    return try openai_compatible.callChat(
        allocator,
        app_config.llama_cpp_base_url,
        maybe_key,
        model_name,
        request,
        "llama.cpp",
    );
}

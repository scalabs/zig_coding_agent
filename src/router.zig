const std = @import("std");
const config = @import("config.zig");
const types = @import("types.zig");
const ollama_qwen = @import("providers/ollama_qwen.zig");
const openrouter = @import("providers/openrouter.zig");
const bedrock = @import("providers/bedrock.zig");

pub fn route(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    request: types.Request,
) !types.Response {
    const provider = request.provider orelse app_config.default_provider;

    return switch (provider) {
        .ollama_qwen => try ollama_qwen.callQwen(allocator, app_config, request),
        .openrouter => try openrouter.callOpenRouter(allocator, app_config, request),
        .bedrock => try bedrock.callBedrock(allocator, app_config, request),
    };
}

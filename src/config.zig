const std = @import("std");
const types = @import("types.zig");

pub const Config = struct {
    default_provider: types.Provider,
    listen_host: []const u8,
    listen_port: u16,
    debug_logging: bool,
    ollama_base_url: []const u8,
    ollama_model: []const u8,
    openrouter_base_url: []const u8,
    openrouter_api_key: []const u8,
    openrouter_http_referer: []const u8,
    openrouter_app_name: []const u8,
    openrouter_model: []const u8,
    bedrock_runtime_base_url: []const u8,
    bedrock_region: []const u8,
    bedrock_access_key_id: []const u8,
    bedrock_secret_access_key: []const u8,
    bedrock_session_token: []const u8,
    bedrock_model: []const u8,

    pub fn load(allocator: std.mem.Allocator) !Config {
        const provider_name = try getEnvOrDefault(
            allocator,
            "LLM_ROUTER_DEFAULT_PROVIDER",
            "ollama_qwen",
        );
        defer allocator.free(provider_name);

        const default_provider = types.Provider.parse(provider_name) orelse {
            return error.InvalidDefaultProvider;
        };

        return Config{
            .default_provider = default_provider,
            .listen_host = try getEnvOrDefault(
                allocator,
                "LLM_ROUTER_HOST",
                "127.0.0.1",
            ),
            .listen_port = try getEnvPortOrDefault("LLM_ROUTER_PORT", 8080),
            .debug_logging = try getEnvFlag(allocator, "LLM_ROUTER_DEBUG"),
            .ollama_base_url = try getEnvOrDefault(
                allocator,
                "OLLAMA_BASE_URL",
                "http://127.0.0.1:11434",
            ),
            .ollama_model = try getEnvOrDefault(
                allocator,
                "OLLAMA_MODEL",
                "qwen:7b",
            ),
            .openrouter_base_url = try getEnvOrDefault(
                allocator,
                "OPENROUTER_BASE_URL",
                "https://openrouter.ai/api/v1",
            ),
            .openrouter_api_key = try getEnvOrDefault(
                allocator,
                "OPENROUTER_API_KEY",
                "",
            ),
            .openrouter_http_referer = try getEnvOrDefault(
                allocator,
                "OPENROUTER_HTTP_REFERER",
                "",
            ),
            .openrouter_app_name = try getEnvOrDefault(
                allocator,
                "OPENROUTER_APP_NAME",
                "",
            ),
            .openrouter_model = try getEnvOrDefault(
                allocator,
                "OPENROUTER_MODEL",
                "openrouter/auto",
            ),
            .bedrock_runtime_base_url = try getFirstEnvOrDefault(
                allocator,
                &.{"BEDROCK_RUNTIME_BASE_URL"},
                "",
            ),
            .bedrock_region = try getFirstEnvOrDefault(
                allocator,
                &.{ "BEDROCK_REGION", "AWS_REGION", "AWS_DEFAULT_REGION" },
                "us-east-1",
            ),
            .bedrock_access_key_id = try getFirstEnvOrDefault(
                allocator,
                &.{ "BEDROCK_ACCESS_KEY_ID", "AWS_ACCESS_KEY_ID" },
                "",
            ),
            .bedrock_secret_access_key = try getFirstEnvOrDefault(
                allocator,
                &.{ "BEDROCK_SECRET_ACCESS_KEY", "AWS_SECRET_ACCESS_KEY" },
                "",
            ),
            .bedrock_session_token = try getFirstEnvOrDefault(
                allocator,
                &.{ "BEDROCK_SESSION_TOKEN", "AWS_SESSION_TOKEN" },
                "",
            ),
            .bedrock_model = try getEnvOrDefault(
                allocator,
                "BEDROCK_MODEL",
                "amazon.nova-micro-v1:0",
            ),
        };
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.listen_host);
        allocator.free(self.ollama_base_url);
        allocator.free(self.ollama_model);
        allocator.free(self.openrouter_base_url);
        allocator.free(self.openrouter_api_key);
        allocator.free(self.openrouter_http_referer);
        allocator.free(self.openrouter_app_name);
        allocator.free(self.openrouter_model);
        allocator.free(self.bedrock_runtime_base_url);
        allocator.free(self.bedrock_region);
        allocator.free(self.bedrock_access_key_id);
        allocator.free(self.bedrock_secret_access_key);
        allocator.free(self.bedrock_session_token);
        allocator.free(self.bedrock_model);
    }
};

fn getEnvOrDefault(
    allocator: std.mem.Allocator,
    key: []const u8,
    default_value: []const u8,
) ![]u8 {
    return std.process.getEnvVarOwned(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, default_value),
        else => err,
    };
}

fn getFirstEnvOrDefault(
    allocator: std.mem.Allocator,
    keys: []const []const u8,
    default_value: []const u8,
) ![]u8 {
    for (keys) |key| {
        const value = std.process.getEnvVarOwned(allocator, key) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => continue,
            else => return err,
        };

        return value;
    }

    return try allocator.dupe(u8, default_value);
}

fn getEnvPortOrDefault(comptime key: []const u8, default_value: u16) !u16 {
    return std.process.parseEnvVarInt(key, u16, 10) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => default_value,
        else => err,
    };
}

fn getEnvFlag(
    allocator: std.mem.Allocator,
    key: []const u8,
) !bool {
    const value = std.process.getEnvVarOwned(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return false,
        else => return err,
    };
    defer allocator.free(value);

    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "0")) return false;
    if (std.ascii.eqlIgnoreCase(value, "false")) return false;
    if (std.ascii.eqlIgnoreCase(value, "no")) return false;

    return true;
}

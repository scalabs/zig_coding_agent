const std = @import("std");
const types = @import("types.zig");

pub const Config = struct {
    listen_host: []const u8,
    listen_port: u16,
    debug_logging: bool,
    default_provider: []const u8,
    instance_id: []const u8,
    auth_api_key: []const u8,
    ollama_base_url: []const u8,
    ollama_model: []const u8,
    ollama_think: bool,
    ollama_num_predict: u32,
    ollama_temperature: f64,
    ollama_repeat_penalty: f64,
    openai_base_url: []const u8,
    openai_api_key: []const u8,
    openai_model: []const u8,
    claude_base_url: []const u8,
    claude_api_key: []const u8,
    claude_model: []const u8,
    llama_cpp_base_url: []const u8,
    llama_cpp_api_key: []const u8,
    llama_cpp_model: []const u8,

    pub fn load(allocator: std.mem.Allocator) !Config {
        const default_provider = try getEnvOrDefault(
            allocator,
            "LLM_ROUTER_PROVIDER",
            "ollama",
        );
        errdefer allocator.free(default_provider);
        try validateProviderName(default_provider);

        return Config{
            .listen_host = try getEnvOrDefault(
                allocator,
                "LLM_ROUTER_HOST",
                "127.0.0.1",
            ),
            .listen_port = try getEnvPortOrDefault("LLM_ROUTER_PORT", 8081),
            .debug_logging = try getEnvFlag(allocator, "LLM_ROUTER_DEBUG"),
            .default_provider = default_provider,
            .instance_id = try getEnvOrDefault(
                allocator,
                "LLM_ROUTER_INSTANCE_ID",
                "local-instance",
            ),
            .auth_api_key = try getEnvOrDefault(
                allocator,
                "LLM_ROUTER_API_KEY",
                "",
            ),
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
            .ollama_think = try getEnvFlag(allocator, "OLLAMA_THINK"),
            .ollama_num_predict = try getEnvU32OrDefault("OLLAMA_NUM_PREDICT", 128),
            .ollama_temperature = try getEnvF64OrDefault(allocator, "OLLAMA_TEMPERATURE", 0.7),
            .ollama_repeat_penalty = try getEnvF64OrDefault(allocator, "OLLAMA_REPEAT_PENALTY", 1.05),
            .openai_base_url = try getEnvOrDefault(
                allocator,
                "OPENAI_BASE_URL",
                "https://api.openai.com/v1",
            ),
            .openai_api_key = try getEnvOrDefault(
                allocator,
                "OPENAI_API_KEY",
                "",
            ),
            .openai_model = try getEnvOrDefault(
                allocator,
                "OPENAI_MODEL",
                "gpt-4.1-mini",
            ),
            .claude_base_url = try getEnvOrDefault(
                allocator,
                "CLAUDE_BASE_URL",
                "https://api.anthropic.com/v1",
            ),
            .claude_api_key = try getEnvOrDefault(
                allocator,
                "CLAUDE_API_KEY",
                "",
            ),
            .claude_model = try getEnvOrDefault(
                allocator,
                "CLAUDE_MODEL",
                "claude-3-5-sonnet-latest",
            ),
            .llama_cpp_base_url = try getEnvOrDefault(
                allocator,
                "LLAMA_CPP_BASE_URL",
                "http://127.0.0.1:8080",
            ),
            .llama_cpp_api_key = try getEnvOrDefault(
                allocator,
                "LLAMA_CPP_API_KEY",
                "",
            ),
            .llama_cpp_model = try getEnvOrDefault(
                allocator,
                "LLAMA_CPP_MODEL",
                "local-model",
            ),
        };
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.listen_host);
        allocator.free(self.default_provider);
        allocator.free(self.instance_id);
        allocator.free(self.auth_api_key);
        allocator.free(self.ollama_base_url);
        allocator.free(self.ollama_model);
        allocator.free(self.openai_base_url);
        allocator.free(self.openai_api_key);
        allocator.free(self.openai_model);
        allocator.free(self.claude_base_url);
        allocator.free(self.claude_api_key);
        allocator.free(self.claude_model);
        allocator.free(self.llama_cpp_base_url);
        allocator.free(self.llama_cpp_api_key);
        allocator.free(self.llama_cpp_model);
    }

    pub fn setDefaultProvider(
        self: *Config,
        allocator: std.mem.Allocator,
        provider: []const u8,
    ) !void {
        try validateProviderName(provider);

        const next_provider = try allocator.dupe(u8, provider);
        allocator.free(self.default_provider);
        self.default_provider = next_provider;
    }
};

fn validateProviderName(provider: []const u8) !void {
    _ = types.normalizeProviderName(provider) orelse return error.InvalidProvider;
}

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

fn getEnvPortOrDefault(comptime key: []const u8, default_value: u16) !u16 {
    return std.process.parseEnvVarInt(key, u16, 10) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => default_value,
        else => err,
    };
}

fn getEnvU32OrDefault(comptime key: []const u8, default_value: u32) !u32 {
    return std.process.parseEnvVarInt(key, u32, 10) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => default_value,
        else => err,
    };
}

fn getEnvF64OrDefault(
    allocator: std.mem.Allocator,
    key: []const u8,
    default_value: f64,
) !f64 {
    const value = std.process.getEnvVarOwned(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return default_value,
        else => return err,
    };
    defer allocator.free(value);

    return try std.fmt.parseFloat(f64, value);
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

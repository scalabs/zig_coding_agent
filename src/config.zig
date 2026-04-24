//! Runtime configuration loaded from environment variables.
const std = @import("std");
const types = @import("types.zig");

pub const EnvOverrides = std.StringHashMap([]const u8);

/// Application configuration with owned string fields.
///
/// Ownership:
/// - all string fields are owned and must be released with `deinit`.
pub const Config = struct {
    listen_host: []const u8,
    listen_port: u16,
    debug_logging: bool,
    default_provider: []const u8,
    request_timeout_ms: u32,
    provider_timeout_ms: u32,
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
    openrouter_base_url: []const u8,
    openrouter_api_key: []const u8,
    openrouter_http_referer: []const u8,
    openrouter_app_name: []const u8,
    openrouter_model: []const u8,
    claude_base_url: []const u8,
    claude_api_key: []const u8,
    claude_model: []const u8,
    bedrock_runtime_base_url: []const u8,
    bedrock_region: []const u8,
    bedrock_access_key_id: []const u8,
    bedrock_secret_access_key: []const u8,
    bedrock_session_token: []const u8,
    bedrock_model: []const u8,
    llama_cpp_base_url: []const u8,
    llama_cpp_api_key: []const u8,
    llama_cpp_model: []const u8,
    session_store_path: []const u8,
    session_retention_messages: usize,
    tool_exec_enabled: bool,
    tool_exec_timeout_ms: u32,
    tool_exec_max_output_bytes: usize,
    loop_stream_progress_enabled: bool,

    pub fn load(allocator: std.mem.Allocator) !Config {
        return try loadWithOverrides(allocator, null);
    }

    pub fn loadWithOverrides(
        allocator: std.mem.Allocator,
        env_overrides: ?*const EnvOverrides,
    ) !Config {
        const requested_default_provider = try getEnvOrDefault(
            allocator,
            "LLM_ROUTER_PROVIDER",
            "ollama",
            env_overrides,
        );
        errdefer allocator.free(requested_default_provider);

        const normalized_default_provider = types.normalizeProviderName(requested_default_provider) orelse {
            return error.InvalidProvider;
        };

        const default_provider = try allocator.dupe(u8, normalized_default_provider);
        allocator.free(requested_default_provider);
        errdefer allocator.free(default_provider);

        return Config{
            .listen_host = try getEnvOrDefault(
                allocator,
                "LLM_ROUTER_HOST",
                "127.0.0.1",
                env_overrides,
            ),
            .listen_port = try getEnvPortOrDefault("LLM_ROUTER_PORT", 8081, env_overrides),
            .debug_logging = try getEnvFlag(allocator, "LLM_ROUTER_DEBUG", env_overrides),
            .default_provider = default_provider,
            .request_timeout_ms = try getEnvPositiveU32OrDefault("LLM_ROUTER_REQUEST_TIMEOUT_MS", 30_000, env_overrides),
            .provider_timeout_ms = try getEnvPositiveU32OrDefault("LLM_ROUTER_PROVIDER_TIMEOUT_MS", 60_000, env_overrides),
            .instance_id = try getEnvOrDefault(
                allocator,
                "LLM_ROUTER_INSTANCE_ID",
                "local-instance",
                env_overrides,
            ),
            .auth_api_key = try getEnvOrDefault(
                allocator,
                "LLM_ROUTER_API_KEY",
                "",
                env_overrides,
            ),
            .ollama_base_url = try getEnvOrDefault(
                allocator,
                "OLLAMA_BASE_URL",
                "http://127.0.0.1:11434",
                env_overrides,
            ),
            .ollama_model = try getEnvOrDefault(
                allocator,
                "OLLAMA_MODEL",
                "qwen3.5:9b",
                env_overrides,
            ),
            .ollama_think = try getEnvFlag(allocator, "OLLAMA_THINK", env_overrides),
            .ollama_num_predict = try getEnvU32OrDefault("OLLAMA_NUM_PREDICT", 128, env_overrides),
            .ollama_temperature = try getEnvF64OrDefault(allocator, "OLLAMA_TEMPERATURE", 0.7, env_overrides),
            .ollama_repeat_penalty = try getEnvF64OrDefault(allocator, "OLLAMA_REPEAT_PENALTY", 1.05, env_overrides),
            .openai_base_url = try getEnvOrDefault(
                allocator,
                "OPENAI_BASE_URL",
                "https://api.openai.com/v1",
                env_overrides,
            ),
            .openai_api_key = try getEnvOrDefault(
                allocator,
                "OPENAI_API_KEY",
                "",
                env_overrides,
            ),
            .openai_model = try getEnvOrDefault(
                allocator,
                "OPENAI_MODEL",
                "gpt-4.1-mini",
                env_overrides,
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
            .claude_base_url = try getEnvOrDefault(
                allocator,
                "CLAUDE_BASE_URL",
                "https://api.anthropic.com/v1",
                env_overrides,
            ),
            .claude_api_key = try getEnvOrDefault(
                allocator,
                "CLAUDE_API_KEY",
                "",
                env_overrides,
            ),
            .claude_model = try getEnvOrDefault(
                allocator,
                "CLAUDE_MODEL",
                "claude-3-5-sonnet-latest",
                env_overrides,
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
            .llama_cpp_base_url = try getEnvOrDefault(
                allocator,
                "LLAMA_CPP_BASE_URL",
                "http://127.0.0.1:8080",
                env_overrides,
            ),
            .llama_cpp_api_key = try getEnvOrDefault(
                allocator,
                "LLAMA_CPP_API_KEY",
                "",
                env_overrides,
            ),
            .llama_cpp_model = try getEnvOrDefault(
                allocator,
                "LLAMA_CPP_MODEL",
                "local-model",
                env_overrides,
            ),
            .session_store_path = try getEnvOrDefault(
                allocator,
                "LLM_ROUTER_SESSION_STORE_PATH",
                "logs/sessions",
                env_overrides,
            ),
            .session_retention_messages = try getEnvPositiveUsizeOrDefault(
                "LLM_ROUTER_SESSION_RETENTION_MESSAGES",
                24,
                env_overrides,
            ),
            .tool_exec_enabled = try getEnvFlag(allocator, "LLM_ROUTER_TOOL_EXEC_ENABLED", env_overrides),
            .tool_exec_timeout_ms = try getEnvPositiveU32OrDefault("LLM_ROUTER_TOOL_EXEC_TIMEOUT_MS", 15_000, env_overrides),
            .tool_exec_max_output_bytes = try getEnvPositiveUsizeOrDefault("LLM_ROUTER_TOOL_EXEC_MAX_OUTPUT_BYTES", 65_536, env_overrides),
            .loop_stream_progress_enabled = try getEnvFlagOrDefault(allocator, "LLM_ROUTER_LOOP_STREAM_PROGRESS_ENABLED", true, env_overrides),
        };
    }

    /// Releases all heap-allocated config strings.
    ///
    /// Args:
    /// - self: config instance containing owned strings.
    /// - allocator: allocator that allocated the config strings.
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
        allocator.free(self.openrouter_base_url);
        allocator.free(self.openrouter_api_key);
        allocator.free(self.openrouter_http_referer);
        allocator.free(self.openrouter_app_name);
        allocator.free(self.openrouter_model);
        allocator.free(self.claude_base_url);
        allocator.free(self.claude_api_key);
        allocator.free(self.claude_model);
        allocator.free(self.bedrock_runtime_base_url);
        allocator.free(self.bedrock_region);
        allocator.free(self.bedrock_access_key_id);
        allocator.free(self.bedrock_secret_access_key);
        allocator.free(self.bedrock_session_token);
        allocator.free(self.bedrock_model);
        allocator.free(self.llama_cpp_base_url);
        allocator.free(self.llama_cpp_api_key);
        allocator.free(self.llama_cpp_model);
        allocator.free(self.session_store_path);
    }

    pub fn setDefaultProvider(
        self: *Config,
        allocator: std.mem.Allocator,
        provider: []const u8,
    ) !void {
        const normalized = types.normalizeProviderName(provider) orelse {
            return error.InvalidProvider;
        };

        const next_provider = try allocator.dupe(u8, normalized);
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
    env_overrides: ?*const EnvOverrides,
) ![]u8 {
    if (env_overrides) |overrides| {
        if (overrides.get(key)) |value| return try allocator.dupe(u8, value);
    }

    return std.process.getEnvVarOwned(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, default_value),
        else => err,
    };
}

<<<<<<< HEAD
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
=======
fn getEnvPortOrDefault(
    comptime key: []const u8,
    default_value: u16,
    env_overrides: ?*const EnvOverrides,
) !u16 {
    if (env_overrides) |overrides| {
        if (overrides.get(key)) |value| {
            return try std.fmt.parseInt(u16, value, 10);
        }
    }

>>>>>>> 00e62e5 (Added command exectution tool)
    return std.process.parseEnvVarInt(key, u16, 10) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => default_value,
        else => err,
    };
}

fn getEnvU32OrDefault(
    comptime key: []const u8,
    default_value: u32,
    env_overrides: ?*const EnvOverrides,
) !u32 {
    if (env_overrides) |overrides| {
        if (overrides.get(key)) |value| {
            return try std.fmt.parseInt(u32, value, 10);
        }
    }

    return std.process.parseEnvVarInt(key, u32, 10) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => default_value,
        else => err,
    };
}

fn getEnvPositiveU32OrDefault(
    comptime key: []const u8,
    default_value: u32,
    env_overrides: ?*const EnvOverrides,
) !u32 {
    const value = try getEnvU32OrDefault(key, default_value, env_overrides);
    if (value == 0) return error.InvalidConfiguration;
    return value;
}

fn getEnvPositiveUsizeOrDefault(
    comptime key: []const u8,
    default_value: usize,
    env_overrides: ?*const EnvOverrides,
) !usize {
    if (env_overrides) |overrides| {
        if (overrides.get(key)) |value| {
            const parsed = try std.fmt.parseInt(usize, value, 10);
            if (parsed == 0) return error.InvalidConfiguration;
            return parsed;
        }
    }

    const value = std.process.parseEnvVarInt(key, usize, 10) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => default_value,
        else => return err,
    };
    if (value == 0) return error.InvalidConfiguration;
    return value;
}

fn getEnvF64OrDefault(
    allocator: std.mem.Allocator,
    key: []const u8,
    default_value: f64,
    env_overrides: ?*const EnvOverrides,
) !f64 {
    if (env_overrides) |overrides| {
        if (overrides.get(key)) |value| {
            return try std.fmt.parseFloat(f64, value);
        }
    }

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
    env_overrides: ?*const EnvOverrides,
) !bool {
    if (env_overrides) |overrides| {
        if (overrides.get(key)) |value| {
            return parseBoolFlag(value);
        }
    }

    const value = std.process.getEnvVarOwned(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return false,
        else => return err,
    };
    defer allocator.free(value);

    return parseBoolFlag(value);
}

fn getEnvFlagOrDefault(
    allocator: std.mem.Allocator,
    key: []const u8,
    default_value: bool,
    env_overrides: ?*const EnvOverrides,
) !bool {
    if (env_overrides) |overrides| {
        if (overrides.get(key)) |value| {
            return parseBoolFlag(value);
        }
    }

    const value = std.process.getEnvVarOwned(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return default_value,
        else => return err,
    };
    defer allocator.free(value);

    return parseBoolFlag(value);
}

fn parseBoolFlag(value: []const u8) bool {
    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "0")) return false;
    if (std.ascii.eqlIgnoreCase(value, "false")) return false;
    if (std.ascii.eqlIgnoreCase(value, "no")) return false;

    return true;
}

test "setDefaultProvider stores canonical provider alias" {
    const allocator = std.testing.allocator;

    var cfg = Config{
        .listen_host = try allocator.dupe(u8, "127.0.0.1"),
        .listen_port = 8081,
        .debug_logging = false,
        .default_provider = try allocator.dupe(u8, "ollama_qwen"),
        .request_timeout_ms = 30_000,
        .provider_timeout_ms = 60_000,
        .instance_id = try allocator.dupe(u8, "local-instance"),
        .auth_api_key = try allocator.dupe(u8, ""),
        .ollama_base_url = try allocator.dupe(u8, "http://127.0.0.1:11434"),
        .ollama_model = try allocator.dupe(u8, "qwen:7b"),
        .ollama_think = false,
        .ollama_num_predict = 512,
        .ollama_temperature = 0.7,
        .ollama_repeat_penalty = 1.05,
        .openai_base_url = try allocator.dupe(u8, "https://api.openai.com/v1"),
        .openai_api_key = try allocator.dupe(u8, ""),
        .openai_model = try allocator.dupe(u8, "gpt-4.1-mini"),
        .openrouter_base_url = try allocator.dupe(u8, "https://openrouter.ai/api/v1"),
        .openrouter_api_key = try allocator.dupe(u8, ""),
        .openrouter_http_referer = try allocator.dupe(u8, ""),
        .openrouter_app_name = try allocator.dupe(u8, ""),
        .openrouter_model = try allocator.dupe(u8, "openrouter/auto"),
        .claude_base_url = try allocator.dupe(u8, "https://api.anthropic.com/v1"),
        .claude_api_key = try allocator.dupe(u8, ""),
        .claude_model = try allocator.dupe(u8, "claude-3-5-sonnet-latest"),
        .bedrock_runtime_base_url = try allocator.dupe(u8, ""),
        .bedrock_region = try allocator.dupe(u8, "us-east-1"),
        .bedrock_access_key_id = try allocator.dupe(u8, ""),
        .bedrock_secret_access_key = try allocator.dupe(u8, ""),
        .bedrock_session_token = try allocator.dupe(u8, ""),
        .bedrock_model = try allocator.dupe(u8, "amazon.nova-micro-v1:0"),
        .llama_cpp_base_url = try allocator.dupe(u8, "http://127.0.0.1:8080"),
        .llama_cpp_api_key = try allocator.dupe(u8, ""),
        .llama_cpp_model = try allocator.dupe(u8, "local-model"),
        .session_store_path = try allocator.dupe(u8, "logs/sessions"),
        .session_retention_messages = 24,
        .tool_exec_enabled = false,
        .tool_exec_timeout_ms = 15_000,
        .tool_exec_max_output_bytes = 65_536,
        .loop_stream_progress_enabled = true,
    };
    defer cfg.deinit(allocator);

    try cfg.setDefaultProvider(allocator, "qwen");
    try std.testing.expectEqualStrings("ollama_qwen", cfg.default_provider);

    try cfg.setDefaultProvider(allocator, "openrouter");
    try std.testing.expectEqualStrings("openrouter", cfg.default_provider);

    try cfg.setDefaultProvider(allocator, "bedrock");
    try std.testing.expectEqualStrings("bedrock", cfg.default_provider);
}

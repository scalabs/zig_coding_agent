//! Runtime configuration loaded from environment variables.
const std = @import("std");
const types = @import("types.zig");

/// Application configuration with owned string fields.
///
/// Ownership:
/// - all string fields are owned and must be released with `deinit`.
pub const Config = struct {
    listen_host: []const u8, // Bind host for server listen socket.
    listen_port: u16, // Bind port for server listen socket.
    debug_logging: bool, // Enables verbose request/response diagnostics.
    default_provider: []const u8, // Canonical provider ID or accepted alias.
    ollama_base_url: []const u8, // Base URL for Ollama HTTP API.
    ollama_model: []const u8, // Default Ollama model when request model is absent.

    /// Loads configuration from environment variables with project defaults.
    ///
    /// Args:
    /// - allocator: allocator used for owned string values.
    ///
    /// Returns:
    /// - !Config: configuration with owned strings and validated default provider.
    ///
    /// Errors:
    /// - `error.InvalidProvider` when provider is not recognized.
    /// - allocation and environment access failures.
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
        allocator.free(self.ollama_base_url);
        allocator.free(self.ollama_model);
    }

    /// Replaces the default provider after validating supported aliases.
    ///
    /// Args:
    /// - self: mutable config to update.
    /// - allocator: allocator used to duplicate the new provider value.
    /// - provider: provider alias or canonical name.
    ///
    /// Errors:
    /// - `error.InvalidProvider` when provider is unknown.
    /// - allocation failures.
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

// Empty, 0, false, and no are treated as false; everything else is true.
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

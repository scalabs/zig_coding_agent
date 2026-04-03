const std = @import("std");

pub const Config = struct {
    listen_host: []const u8,
    listen_port: u16,
    debug_logging: bool,
    ollama_base_url: []const u8,
    ollama_model: []const u8,

    pub fn load(allocator: std.mem.Allocator) !Config {
        return Config{
            .listen_host = try getEnvOrDefault(
                allocator,
                "LLM_ROUTER_HOST",
                "127.0.0.1",
            ),
            .listen_port = try getEnvPortOrDefault("LLM_ROUTER_PORT", 8081),
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
        };
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.listen_host);
        allocator.free(self.ollama_base_url);
        allocator.free(self.ollama_model);
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

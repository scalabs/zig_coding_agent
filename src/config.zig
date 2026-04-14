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
        var dotenv = try Dotenv.load(allocator);
        defer dotenv.deinit(allocator);

        const default_provider = try getSettingOrDefault(
            allocator,
            &dotenv,
            "LLM_ROUTER_PROVIDER",
            "ollama",
        );
        errdefer allocator.free(default_provider);
        try validateProviderName(default_provider);

        const listen_host = try getSettingOrDefault(
            allocator,
            &dotenv,
            "LLM_ROUTER_HOST",
            "127.0.0.1",
        );
        errdefer allocator.free(listen_host);

        const listen_port = try getPortSettingOrDefault(&dotenv, "LLM_ROUTER_PORT", 8081);

        const debug_logging = try getSettingFlag(allocator, &dotenv, "LLM_ROUTER_DEBUG");

        const ollama_base_url = try getSettingOrDefault(
            allocator,
            &dotenv,
            "OLLAMA_BASE_URL",
            "http://127.0.0.1:11434",
        );
        errdefer allocator.free(ollama_base_url);

        const ollama_model = try getSettingOrDefault(
            allocator,
            &dotenv,
            "OLLAMA_MODEL",
            "qwen:7b",
        );
        errdefer allocator.free(ollama_model);

        return Config{
            .listen_host = listen_host,
            .listen_port = listen_port,
            .debug_logging = debug_logging,
            .default_provider = default_provider,
            .ollama_base_url = ollama_base_url,
            .ollama_model = ollama_model,
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

const Dotenv = struct {
    values: std.StringHashMap([]u8),

    fn load(allocator: std.mem.Allocator) !Dotenv {
        var values = std.StringHashMap([]u8).init(allocator);
        errdefer {
            var it = values.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            values.deinit();
        }

        const content = std.fs.cwd().readFileAlloc(allocator, ".env", 256 * 1024) catch |err| switch (err) {
            error.FileNotFound => {
                return .{ .values = values };
            },
            else => return err,
        };
        defer allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, std.mem.trimRight(u8, line_raw, "\r"), " \t");
            if (line.len == 0 or line[0] == '#') continue;

            const separator_index = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key_slice = std.mem.trim(u8, line[0..separator_index], " \t");
            var value_slice = std.mem.trim(u8, line[separator_index + 1 ..], " \t");

            if (key_slice.len == 0) continue;

            if (value_slice.len >= 2) {
                const first = value_slice[0];
                const last = value_slice[value_slice.len - 1];
                if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
                    value_slice = value_slice[1 .. value_slice.len - 1];
                }
            }

            const value_copy = try allocator.dupe(u8, value_slice);
            errdefer allocator.free(value_copy);

            if (values.getPtr(key_slice)) |existing| {
                allocator.free(existing.*);
                existing.* = value_copy;
                continue;
            }

            const key_copy = try allocator.dupe(u8, key_slice);
            errdefer allocator.free(key_copy);
            try values.put(key_copy, value_copy);
        }

        return .{ .values = values };
    }

    fn deinit(self: *Dotenv, allocator: std.mem.Allocator) void {
        var it = self.values.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.values.deinit();
    }

    fn get(self: *const Dotenv, key: []const u8) ?[]const u8 {
        return self.values.get(key);
    }
};

fn getSettingOrDefault(
    allocator: std.mem.Allocator,
    dotenv: *const Dotenv,
    key: []const u8,
    default_value: []const u8,
) ![]u8 {
    return std.process.getEnvVarOwned(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            if (dotenv.get(key)) |value| {
                return try allocator.dupe(u8, value);
            }
            return try allocator.dupe(u8, default_value);
        },
        else => err,
    };
}

fn getPortSettingOrDefault(
    dotenv: *const Dotenv,
    comptime key: []const u8,
    default_value: u16,
) !u16 {
    return std.process.parseEnvVarInt(key, u16, 10) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            if (dotenv.get(key)) |value| {
                return try std.fmt.parseInt(u16, value, 10);
            }
            return default_value;
        },
        else => err,
    };
}

// Empty, 0, false, and no are treated as false; everything else is true.
fn getSettingFlag(
    allocator: std.mem.Allocator,
    dotenv: *const Dotenv,
    key: []const u8,
) !bool {
    const value = getSettingOrDefault(allocator, dotenv, key, "") catch |err| switch (err) {
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

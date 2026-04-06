const std = @import("std");
const root = @import("root.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const provider_override = try parseProviderOverride(allocator);
    defer if (provider_override) |provider| allocator.free(provider);

    var app_config = try root.config.Config.load(allocator);
    defer app_config.deinit(allocator);

    if (provider_override) |provider| {
        try app_config.setDefaultProvider(allocator, provider);
    }

    try root.core.run(allocator, &app_config);
}

fn parseProviderOverride(allocator: std.mem.Allocator) !?[]u8 {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();

    var provider_override: ?[]u8 = null;
    errdefer if (provider_override) |provider| allocator.free(provider);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--provider")) {
            const value = args.next() orelse return error.MissingProviderValue;
            if (provider_override) |provider| allocator.free(provider);
            provider_override = try allocator.dupe(u8, value);
            continue;
        }

        const provider_prefix = "--provider=";
        if (std.mem.startsWith(u8, arg, provider_prefix)) {
            const value = arg[provider_prefix.len..];
            if (value.len == 0) return error.MissingProviderValue;
            if (provider_override) |provider| allocator.free(provider);
            provider_override = try allocator.dupe(u8, value);
        }
    }

    return provider_override;
}


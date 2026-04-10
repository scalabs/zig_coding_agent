const std = @import("std");
const types = @import("../types.zig");

pub const ToolRegistry = struct {
    allowed_names: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) ToolRegistry {
        return .{ .allowed_names = std.StringHashMap(void).init(allocator) };
    }

    pub fn deinit(self: *ToolRegistry, allocator: std.mem.Allocator) void {
        var iterator = self.allowed_names.keyIterator();
        while (iterator.next()) |key| {
            allocator.free(key.*);
        }
        self.allowed_names.deinit();
    }

    pub fn register(self: *ToolRegistry, allocator: std.mem.Allocator, name: []const u8) !void {
        const key = try allocator.dupe(u8, name);
        errdefer allocator.free(key);
        try self.allowed_names.put(key, {});
    }

    pub fn isAllowed(self: *const ToolRegistry, name: []const u8) bool {
        return self.allowed_names.contains(name);
    }
};

pub fn validateRequestedTools(
    registry: *const ToolRegistry,
    tools: []const types.Tool,
) bool {
    for (tools) |tool| {
        if (!registry.isAllowed(tool.name)) return false;
    }
    return true;
}

const std = @import("std");
const types = @import("../types.zig");
const echo_tool = @import("../tools/echo.zig");
const utc_tool = @import("../tools/utc.zig");

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

/// Executes simple built-in debug tools directly in the harness.
///
/// This is intentionally minimal and deterministic so UI clients can verify
/// tool wiring without depending on upstream model behavior.
pub fn tryExecuteDebugTool(
    allocator: std.mem.Allocator,
    request: types.Request,
) !?types.Response {
    const choice = request.tool_choice orelse return null;

    if (std.ascii.eqlIgnoreCase(choice, "echo")) {
        if (!hasRequestedTool(request.tools, "echo")) return null;
        return try echo_tool.execute(allocator, request);
    }

    if (std.ascii.eqlIgnoreCase(choice, "utc")) {
        if (!hasRequestedTool(request.tools, "utc")) return null;
        return try utc_tool.execute(allocator, request);
    }

    return null;
}

fn hasRequestedTool(tools: []const types.Tool, name: []const u8) bool {
    for (tools) |tool| {
        if (std.ascii.eqlIgnoreCase(tool.name, name)) return true;
    }
    return false;
}

test "tryExecuteDebugTool executes echo when explicitly selected" {
    const allocator = std.testing.allocator;

    const messages = try allocator.alloc(types.Message, 1);
    messages[0] = .{
        .role = try allocator.dupe(u8, "user"),
        .content = try allocator.dupe(u8, "ping"),
    };

    const tools = try allocator.alloc(types.Tool, 1);
    tools[0] = .{
        .name = try allocator.dupe(u8, "echo"),
        .description = try allocator.dupe(u8, "debug echo"),
    };

    const req = types.Request{
        .prompt = try allocator.dupe(u8, "ping"),
        .messages = messages,
        .provider = null,
        .model = null,
        .session_id = null,
        .tenant_id = null,
        .max_context_tokens = null,
        .tools = tools,
        .tool_choice = try allocator.dupe(u8, "echo"),
    };
    defer req.deinit(allocator);

    const maybe_result = try tryExecuteDebugTool(allocator, req);
    try std.testing.expect(maybe_result != null);

    var result = maybe_result.?;
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("debug-tools/echo", result.model);
    try std.testing.expectEqualStrings("tool", result.finish_reason);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DEBUG_TOOL_OK") != null);
}

test "tryExecuteDebugTool executes utc when explicitly selected" {
    const allocator = std.testing.allocator;

    const messages = try allocator.alloc(types.Message, 1);
    messages[0] = .{
        .role = try allocator.dupe(u8, "user"),
        .content = try allocator.dupe(u8, "time"),
    };

    const tools = try allocator.alloc(types.Tool, 1);
    tools[0] = .{
        .name = try allocator.dupe(u8, "utc"),
        .description = try allocator.dupe(u8, "current utc time"),
    };

    const req = types.Request{
        .prompt = try allocator.dupe(u8, "time"),
        .messages = messages,
        .provider = null,
        .model = null,
        .session_id = null,
        .tenant_id = null,
        .max_context_tokens = null,
        .tools = tools,
        .tool_choice = try allocator.dupe(u8, "utc"),
    };
    defer req.deinit(allocator);

    const maybe_result = try tryExecuteDebugTool(allocator, req);
    try std.testing.expect(maybe_result != null);

    var result = maybe_result.?;
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("debug-tools/utc", result.model);
    try std.testing.expectEqualStrings("tool", result.finish_reason);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "tool=utc") != null);
}

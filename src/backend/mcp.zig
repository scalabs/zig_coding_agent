//! Minimal MCP discovery bridge.
//!
//! This module intentionally stops at bounded tool metadata parsing and
//! allowlist registration. Transport and invocation stay outside the hot path
//! until an MCP server is explicitly wired in.
const std = @import("std");
const types = @import("../types.zig");
const tooling = @import("tools.zig");

pub fn parseDiscoveredToolsAlloc(
    allocator: std.mem.Allocator,
    discovery_json: []const u8,
    max_tools: usize,
) ![]types.Tool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, discovery_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return try allocator.alloc(types.Tool, 0),
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return try allocator.alloc(types.Tool, 0),
    };

    const tools_value = root.get("tools") orelse return try allocator.alloc(types.Tool, 0);
    const tool_items = switch (tools_value) {
        .array => |array| array.items,
        else => return try allocator.alloc(types.Tool, 0),
    };

    var out = std.ArrayList(types.Tool){};
    errdefer {
        for (out.items) |tool| {
            tool.deinit(allocator);
        }
        out.deinit(allocator);
    }

    for (tool_items) |item| {
        if (out.items.len >= max_tools) break;

        const object = switch (item) {
            .object => |value| value,
            else => continue,
        };

        const raw_name = switch (object.get("name") orelse continue) {
            .string => |value| std.mem.trim(u8, value, " \t\r\n"),
            else => continue,
        };
        if (!isSafeToolName(raw_name)) continue;
        if (hasToolNamed(out.items, raw_name)) continue;

        const raw_description = if (object.get("description")) |description|
            switch (description) {
                .string => |value| std.mem.trim(u8, value, " \t\r\n"),
                else => "",
            }
        else
            "";

        try out.append(allocator, .{
            .name = try allocator.dupe(u8, raw_name),
            .description = try allocator.dupe(u8, raw_description[0..@min(raw_description.len, 512)]),
        });
    }

    return try out.toOwnedSlice(allocator);
}

pub fn registerDiscoveredTools(
    registry: *tooling.ToolRegistry,
    allocator: std.mem.Allocator,
    discovered_tools: []const types.Tool,
) !void {
    for (discovered_tools) |tool| {
        try registry.register(allocator, tool.name);
    }
}

fn hasToolNamed(tools: []const types.Tool, name: []const u8) bool {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return true;
    }
    return false;
}

fn isSafeToolName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
            else => return false,
        }
    }
    return true;
}

test "parseDiscoveredToolsAlloc maps bounded MCP metadata" {
    const allocator = std.testing.allocator;
    const json =
        \\{"tools":[
        \\  {"name":"search.docs","description":"Search project docs"},
        \\  {"name":"bad name","description":"rejected"},
        \\  {"name":"search.docs","description":"duplicate"}
        \\]}
    ;

    const tools = try parseDiscoveredToolsAlloc(allocator, json, 8);
    defer {
        for (tools) |tool| {
            tool.deinit(allocator);
        }
        allocator.free(tools);
    }

    try std.testing.expectEqual(@as(usize, 1), tools.len);
    try std.testing.expectEqualStrings("search.docs", tools[0].name);
}

test "registerDiscoveredTools maps MCP tools into allowlist" {
    const allocator = std.testing.allocator;
    const discovered = [_]types.Tool{
        .{ .name = "search.docs", .description = "Search project docs" },
    };

    var registry = tooling.ToolRegistry.init(allocator);
    defer registry.deinit(allocator);

    try registerDiscoveredTools(&registry, allocator, discovered[0..]);
    try std.testing.expect(registry.isAllowed("search.docs"));
}

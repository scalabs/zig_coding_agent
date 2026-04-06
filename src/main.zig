const std = @import("std");
const root = @import("root.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app_config = try root.config.Config.load(allocator);
    defer app_config.deinit(allocator);

    try root.core.run(allocator, &app_config);
}


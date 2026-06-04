const std = @import("std");
const web_server = @import("frontend/web_server.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    try web_server.run(gpa.allocator());
}

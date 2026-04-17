const std = @import("std");
const types = @import("../types.zig");

pub fn execute(
    allocator: std.mem.Allocator,
    request: types.Request,
) !types.Response {
    const output = try std.fmt.allocPrint(
        allocator,
        "DEBUG_TOOL_OK\ntool=echo\nprompt={s}\nmessages={d}",
        .{ request.prompt, request.messages.len },
    );
    errdefer allocator.free(output);

    return .{
        .id = null,
        .model = try allocator.dupe(u8, "debug-tools/echo"),
        .output = output,
        .finish_reason = try allocator.dupe(u8, "tool"),
        .success = true,
        .usage = .{},
    };
}

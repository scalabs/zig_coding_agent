const std = @import("std");
const types = @import("../types.zig");

pub fn execute(
    allocator: std.mem.Allocator,
    request: types.Request,
) !types.Response {
    _ = request;

    const now_unix = std.time.timestamp();
    const now_millis = std.time.milliTimestamp();

    const output = try std.fmt.allocPrint(
        allocator,
        "DEBUG_TOOL_OK\ntool=utc\nunix_utc={d}\nutc_millis={d}",
        .{ now_unix, now_millis },
    );
    errdefer allocator.free(output);

    return .{
        .id = null,
        .model = try allocator.dupe(u8, "debug-tools/utc"),
        .output = output,
        .finish_reason = try allocator.dupe(u8, "tool"),
        .success = true,
        .usage = .{},
    };
}

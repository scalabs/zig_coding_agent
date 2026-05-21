//! Echo debug tool.
//!
//! Returns the prompt text and message count as a diagnostic
//! response to verify tool wiring without relying on upstream
//! model behavior.

const std = @import("std");
const types = @import("../types.zig");

/// Returns a debug response echoing the request prompt and message count.
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

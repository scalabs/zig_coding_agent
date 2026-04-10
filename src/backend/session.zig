const std = @import("std");
const types = @import("../types.zig");

pub const SessionState = struct {
    session_id: []const u8,
    tenant_id: ?[]const u8,
    summary: []const u8,
    message_count: usize,

    pub fn deinit(self: SessionState, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        if (self.tenant_id) |tenant_id| allocator.free(tenant_id);
        allocator.free(self.summary);
    }
};

pub fn estimateTokenCount(messages: []const types.Message) usize {
    var chars: usize = 0;
    for (messages) |message| {
        chars += message.role.len;
        chars += message.content.len;
    }
    return chars / 4;
}

pub fn shouldCompressContext(estimated_tokens: usize, max_context_tokens: usize) bool {
    return estimated_tokens > max_context_tokens;
}

pub fn compressContextSummaryAlloc(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
    keep_last_messages: usize,
) ![]u8 {
    if (messages.len <= keep_last_messages) {
        return try allocator.dupe(u8, "");
    }

    const summarize_until = messages.len - keep_last_messages;
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "Summary of previous context:\n");
    for (messages[0..summarize_until]) |message| {
        try out.writer(allocator).print("- {s}: {s}\n", .{ message.role, message.content });
    }

    return try out.toOwnedSlice(allocator);
}

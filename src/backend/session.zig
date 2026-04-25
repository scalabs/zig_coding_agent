const std = @import("std");
const types = @import("../types.zig");

pub const SessionStore = struct {
    ctx: *anyopaque,
    loadFn: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        session_id: []const u8,
        tenant_id: ?[]const u8,
    ) anyerror!?SessionState,
    saveFn: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        state: SessionState,
    ) anyerror!void,
    deinitFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void,

    pub fn load(
        self: *SessionStore,
        allocator: std.mem.Allocator,
        session_id: []const u8,
        tenant_id: ?[]const u8,
    ) !?SessionState {
        return try self.loadFn(self.ctx, allocator, session_id, tenant_id);
    }

    pub fn save(
        self: *SessionStore,
        allocator: std.mem.Allocator,
        state: SessionState,
    ) !void {
        try self.saveFn(self.ctx, allocator, state);
    }

    pub fn deinit(self: *SessionStore, allocator: std.mem.Allocator) void {
        self.deinitFn(self.ctx, allocator);
    }
};

pub const SessionState = struct {
    session_id: []const u8,
    tenant_id: ?[]const u8,
    summary: []const u8,
    messages: []types.Message,
    message_count: usize,

    pub fn initEmpty(
        allocator: std.mem.Allocator,
        session_id: []const u8,
        tenant_id: ?[]const u8,
    ) !SessionState {
        return .{
            .session_id = try allocator.dupe(u8, session_id),
            .tenant_id = if (tenant_id) |value| try allocator.dupe(u8, value) else null,
            .summary = try allocator.dupe(u8, ""),
            .messages = try allocator.alloc(types.Message, 0),
            .message_count = 0,
        };
    }

    pub fn deinit(self: SessionState, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        if (self.tenant_id) |tenant_id| allocator.free(tenant_id);
        allocator.free(self.summary);
        for (self.messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(self.messages);
    }
};

pub const FileSessionStore = struct {
    base_path: []u8,
    retention_messages: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        base_path: []const u8,
        retention_messages: usize,
    ) !FileSessionStore {
        const owned_path = try allocator.dupe(u8, base_path);
        errdefer allocator.free(owned_path);

        try std.fs.cwd().makePath(owned_path);

        return .{
            .base_path = owned_path,
            .retention_messages = retention_messages,
        };
    }

    pub fn asStore(self: *FileSessionStore) SessionStore {
        return .{
            .ctx = self,
            .loadFn = fileStoreLoad,
            .saveFn = fileStoreSave,
            .deinitFn = fileStoreDeinit,
        };
    }

    pub fn deinit(self: *FileSessionStore, allocator: std.mem.Allocator) void {
        allocator.free(self.base_path);
    }
};

pub fn cloneMessagesAlloc(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
) ![]types.Message {
    var out = try allocator.alloc(types.Message, messages.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |message| {
            message.deinit(allocator);
        }
        allocator.free(out);
    }

    for (messages, 0..) |message, idx| {
        out[idx] = .{
            .role = try allocator.dupe(u8, message.role),
            .content = try allocator.dupe(u8, message.content),
        };
        initialized += 1;
    }

    return out;
}

pub fn mergeMessagesAlloc(
    allocator: std.mem.Allocator,
    history: []const types.Message,
    incoming: []const types.Message,
) ![]types.Message {
    var merged = std.ArrayList(types.Message){};
    errdefer {
        for (merged.items) |message| {
            message.deinit(allocator);
        }
        merged.deinit(allocator);
    }

    for (history) |message| {
        try merged.append(allocator, .{
            .role = try allocator.dupe(u8, message.role),
            .content = try allocator.dupe(u8, message.content),
        });
    }

    for (incoming) |message| {
        try merged.append(allocator, .{
            .role = try allocator.dupe(u8, message.role),
            .content = try allocator.dupe(u8, message.content),
        });
    }

    return try merged.toOwnedSlice(allocator);
}

pub fn appendAssistantMessageAlloc(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
    assistant_content: []const u8,
) ![]types.Message {
    var out = std.ArrayList(types.Message){};
    errdefer {
        for (out.items) |message| {
            message.deinit(allocator);
        }
        out.deinit(allocator);
    }

    for (messages) |message| {
        try out.append(allocator, .{
            .role = try allocator.dupe(u8, message.role),
            .content = try allocator.dupe(u8, message.content),
        });
    }

    try out.append(allocator, .{
        .role = try allocator.dupe(u8, "assistant"),
        .content = try allocator.dupe(u8, assistant_content),
    });

    return try out.toOwnedSlice(allocator);
}

pub fn trimToRetentionAlloc(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
    retention_messages: usize,
) ![]types.Message {
    if (retention_messages == 0 or messages.len <= retention_messages) {
        return try cloneMessagesAlloc(allocator, messages);
    }

    const start = messages.len - retention_messages;
    return try cloneMessagesAlloc(allocator, messages[start..]);
}

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

fn fileStoreLoad(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    session_id: []const u8,
    tenant_id: ?[]const u8,
) !?SessionState {
    const store: *FileSessionStore = @ptrCast(@alignCast(ctx));
    const file_path = try sessionFilePathAlloc(allocator, store.base_path, session_id, tenant_id);
    defer allocator.free(file_path);

    const raw = std.fs.cwd().readFileAlloc(allocator, file_path, 8 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(raw);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidSessionData,
    };

    const summary = if (obj.get("summary")) |summary_value|
        switch (summary_value) {
            .string => |value| try allocator.dupe(u8, value),
            else => return error.InvalidSessionData,
        }
    else
        try allocator.dupe(u8, "");
    errdefer allocator.free(summary);

    const loaded_messages = if (obj.get("messages")) |messages_value|
        try parseMessagesAlloc(allocator, messages_value)
    else
        try allocator.alloc(types.Message, 0);
    errdefer {
        for (loaded_messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(loaded_messages);
    }

    const retained = try trimToRetentionAlloc(allocator, loaded_messages, store.retention_messages);
    for (loaded_messages) |message| {
        message.deinit(allocator);
    }
    allocator.free(loaded_messages);

    return .{
        .session_id = try allocator.dupe(u8, session_id),
        .tenant_id = if (tenant_id) |value| try allocator.dupe(u8, value) else null,
        .summary = summary,
        .messages = retained,
        .message_count = retained.len,
    };
}

fn fileStoreSave(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    state: SessionState,
) !void {
    const store: *FileSessionStore = @ptrCast(@alignCast(ctx));
    const file_path = try sessionFilePathAlloc(allocator, store.base_path, state.session_id, state.tenant_id);
    defer allocator.free(file_path);

    const retained = try trimToRetentionAlloc(allocator, state.messages, store.retention_messages);
    defer {
        for (retained) |message| {
            message.deinit(allocator);
        }
        allocator.free(retained);
    }

    const payload = try renderSessionJsonAlloc(allocator, state, retained);
    defer allocator.free(payload);

    try std.fs.cwd().writeFile(.{
        .sub_path = file_path,
        .data = payload,
    });
}

fn fileStoreDeinit(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const store: *FileSessionStore = @ptrCast(@alignCast(ctx));
    store.deinit(allocator);
}

fn sessionFilePathAlloc(
    allocator: std.mem.Allocator,
    base_path: []const u8,
    session_id: []const u8,
    tenant_id: ?[]const u8,
) ![]u8 {
    const safe_session = try sanitizeKeyAlloc(allocator, session_id);
    defer allocator.free(safe_session);

    const safe_tenant = if (tenant_id) |value| try sanitizeKeyAlloc(allocator, value) else try allocator.dupe(u8, "global");
    defer allocator.free(safe_tenant);

    return try std.fmt.allocPrint(
        allocator,
        "{s}/{s}__{s}.json",
        .{ base_path, safe_tenant, safe_session },
    );
}

fn sanitizeKeyAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    for (value) |char| {
        if (std.ascii.isAlphanumeric(char) or char == '_' or char == '-' or char == '.') {
            try out.append(allocator, char);
        } else {
            try out.append(allocator, '_');
        }
    }

    if (out.items.len == 0) {
        try out.appendSlice(allocator, "session");
    }

    return try out.toOwnedSlice(allocator);
}

fn parseMessagesAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) ![]types.Message {
    const array = switch (value) {
        .array => |items| items,
        else => return error.InvalidSessionData,
    };

    var messages = std.ArrayList(types.Message){};
    errdefer {
        for (messages.items) |message| {
            message.deinit(allocator);
        }
        messages.deinit(allocator);
    }

    for (array.items) |item| {
        const obj = switch (item) {
            .object => |object| object,
            else => return error.InvalidSessionData,
        };

        const role = switch (obj.get("role") orelse return error.InvalidSessionData) {
            .string => |text| text,
            else => return error.InvalidSessionData,
        };

        const content = switch (obj.get("content") orelse return error.InvalidSessionData) {
            .string => |text| text,
            else => return error.InvalidSessionData,
        };

        try messages.append(allocator, .{
            .role = try allocator.dupe(u8, role),
            .content = try allocator.dupe(u8, content),
        });
    }

    return try messages.toOwnedSlice(allocator);
}

fn renderSessionJsonAlloc(
    allocator: std.mem.Allocator,
    state: SessionState,
    retained_messages: []const types.Message,
) ![]u8 {
    const escaped_session_id = try escapeJsonStringAlloc(allocator, state.session_id);
    defer allocator.free(escaped_session_id);

    const tenant_json = if (state.tenant_id) |tenant| blk: {
        const escaped = try escapeJsonStringAlloc(allocator, tenant);
        defer allocator.free(escaped);
        break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
    } else try allocator.dupe(u8, "null");
    defer allocator.free(tenant_json);

    const escaped_summary = try escapeJsonStringAlloc(allocator, state.summary);
    defer allocator.free(escaped_summary);

    const messages_json = try renderMessagesJsonAlloc(allocator, retained_messages);
    defer allocator.free(messages_json);

    return try std.fmt.allocPrint(
        allocator,
        "{{\"session_id\":\"{s}\",\"tenant_id\":{s},\"summary\":\"{s}\",\"updated_at_ms\":{d},\"messages\":{s}}}",
        .{
            escaped_session_id,
            tenant_json,
            escaped_summary,
            std.time.milliTimestamp(),
            messages_json,
        },
    );
}

fn renderMessagesJsonAlloc(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try out.append(allocator, '[');
    for (messages, 0..) |message, idx| {
        if (idx > 0) {
            try out.append(allocator, ',');
        }

        const escaped_role = try escapeJsonStringAlloc(allocator, message.role);
        defer allocator.free(escaped_role);

        const escaped_content = try escapeJsonStringAlloc(allocator, message.content);
        defer allocator.free(escaped_content);

        try out.writer(allocator).print(
            "{{\"role\":\"{s}\",\"content\":\"{s}\"}}",
            .{ escaped_role, escaped_content },
        );
    }
    try out.append(allocator, ']');

    return try out.toOwnedSlice(allocator);
}

fn escapeJsonStringAlloc(
    allocator: std.mem.Allocator,
    input: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x00...0x08, 0x0b...0x0c, 0x0e...0x1f, 0x7f => {
                // Escape remaining control characters as \uXXXX per RFC 8259.
                try out.writer(allocator).print("\\u{X:0>4}", .{c});
            },
            else => try out.append(allocator, c),
        }
    }

    return try out.toOwnedSlice(allocator);
}

test "trimToRetentionAlloc keeps latest messages" {
    const allocator = std.testing.allocator;
    var messages = try allocator.alloc(types.Message, 3);
    defer {
        for (messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(messages);
    }

    messages[0] = .{ .role = try allocator.dupe(u8, "user"), .content = try allocator.dupe(u8, "one") };
    messages[1] = .{ .role = try allocator.dupe(u8, "assistant"), .content = try allocator.dupe(u8, "two") };
    messages[2] = .{ .role = try allocator.dupe(u8, "user"), .content = try allocator.dupe(u8, "three") };

    const trimmed = try trimToRetentionAlloc(allocator, messages, 2);
    defer {
        for (trimmed) |message| {
            message.deinit(allocator);
        }
        allocator.free(trimmed);
    }

    try std.testing.expectEqual(@as(usize, 2), trimmed.len);
    try std.testing.expectEqualStrings("two", trimmed[0].content);
    try std.testing.expectEqualStrings("three", trimmed[1].content);
}

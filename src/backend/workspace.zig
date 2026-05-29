//! Lightweight ephemeral workspace memory (Cursor-like, cleared on server exit).
//!
//! Stores conversation turns and a small file-activity hint keyed by `workspace_id`.
//! Does not replace the core harness loop; it only substitutes disk `session_id` with
//! in-process state and enables repo-root file tools when workspace mode is on.
const std = @import("std");
const types = @import("../types.zig");
const session = @import("session.zig");

pub const max_file_hints = 16;

pub const WorkspaceState = struct {
    workspace_id: []const u8,
    messages: []types.Message,
    file_hints: [][]const u8,

    pub fn deinit(self: *WorkspaceState, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_id);
        for (self.messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(self.messages);
        for (self.file_hints) |hint| {
            allocator.free(hint);
        }
        allocator.free(self.file_hints);
    }
};

pub const WorkspaceStore = struct {
    mutex: std.Thread.Mutex = .{},
    workspaces: std.StringHashMap(*WorkspaceState),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) WorkspaceStore {
        return .{
            .workspaces = std.StringHashMap(*WorkspaceState).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WorkspaceStore) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.workspaces.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.workspaces.deinit();
    }

    pub fn count(self: *WorkspaceStore) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.workspaces.count();
    }

    pub fn getOrCreate(self: *WorkspaceStore, workspace_id: []const u8) !*WorkspaceState {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.workspaces.get(workspace_id)) |existing| {
            return existing;
        }

        const owned_id = try self.allocator.dupe(u8, workspace_id);
        errdefer self.allocator.free(owned_id);

        const state = try self.allocator.create(WorkspaceState);
        errdefer self.allocator.destroy(state);

        state.* = .{
            .workspace_id = owned_id,
            .messages = try self.allocator.alloc(types.Message, 0),
            .file_hints = &.{},
        };

        try self.workspaces.put(owned_id, state);
        return state;
    }

    pub fn saveMessages(
        self: *WorkspaceStore,
        workspace: *WorkspaceState,
        messages: []types.Message,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (workspace.messages) |message| {
            message.deinit(self.allocator);
        }
        self.allocator.free(workspace.messages);
        workspace.messages = messages;
    }
};

pub fn mergeIncomingMessagesAlloc(
    allocator: std.mem.Allocator,
    existing: []const types.Message,
    incoming: []const types.Message,
) ![]types.Message {
    if (existing.len == 0) {
        return try session.cloneMessagesAlloc(allocator, incoming);
    }
    if (incoming.len == 0) {
        return try session.cloneMessagesAlloc(allocator, existing);
    }

    const last_incoming = incoming[incoming.len - 1];
    const last_existing = existing[existing.len - 1];
    if (std.mem.eql(u8, last_existing.role, last_incoming.role) and
        std.mem.eql(u8, last_existing.content, last_incoming.content))
    {
        return try session.cloneMessagesAlloc(allocator, existing);
    }

    return try session.mergeMessagesAlloc(allocator, existing, incoming);
}

pub fn recordFileHint(
    workspace: *WorkspaceState,
    allocator: std.mem.Allocator,
    operation: []const u8,
    path: []const u8,
) !void {
    const hint = try std.fmt.allocPrint(allocator, "{s} {s}", .{ operation, path });
    errdefer allocator.free(hint);

    if (workspace.file_hints.len >= max_file_hints) {
        allocator.free(workspace.file_hints[0]);
        for (workspace.file_hints[1..], 0..) |entry, idx| {
            workspace.file_hints[idx] = entry;
        }
        workspace.file_hints[workspace.file_hints.len - 1] = hint;
        return;
    }

    const next = try allocator.realloc(workspace.file_hints, workspace.file_hints.len + 1);
    next[next.len - 1] = hint;
    workspace.file_hints = next;
}

pub fn buildMemoryHintMessageAlloc(
    allocator: std.mem.Allocator,
    workspace: *const WorkspaceState,
) !?types.Message {
    if (workspace.file_hints.len == 0) return null;

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "Workspace memory (cleared on server exit):\n");
    for (workspace.file_hints) |hint| {
        try out.writer(allocator).print("- {s}\n", .{hint});
    }

    return types.Message{
        .role = try allocator.dupe(u8, "system"),
        .content = try out.toOwnedSlice(allocator),
    };
}

pub fn prependMemoryHintAlloc(
    allocator: std.mem.Allocator,
    workspace: *const WorkspaceState,
    messages: []const types.Message,
) ![]types.Message {
    const hint = try buildMemoryHintMessageAlloc(allocator, workspace);
    if (hint == null) {
        return try session.cloneMessagesAlloc(allocator, messages);
    }
    defer hint.?.deinit(allocator);

    var out = std.ArrayList(types.Message){};
    errdefer {
        for (out.items) |message| {
            message.deinit(allocator);
        }
        out.deinit(allocator);
    }

    try out.append(allocator, .{
        .role = try allocator.dupe(u8, hint.?.role),
        .content = try allocator.dupe(u8, hint.?.content),
    });

    for (messages) |message| {
        try out.append(allocator, .{
            .role = try allocator.dupe(u8, message.role),
            .content = try allocator.dupe(u8, message.content),
        });
    }

    return try out.toOwnedSlice(allocator);
}

test "WorkspaceStore is ephemeral and keyed by id" {
    const allocator = std.testing.allocator;
    var store = WorkspaceStore.init(allocator);
    defer store.deinit();

    const ws = try store.getOrCreate("dev");
    const incoming = [_]types.Message{.{ .role = "user", .content = "hi" }};
    const merged = try mergeIncomingMessagesAlloc(allocator, ws.messages, incoming[0..]);
    try store.saveMessages(ws, merged);

    try std.testing.expectEqual(@as(usize, 1), ws.messages.len);
    try std.testing.expectEqual(@as(usize, 1), store.count());
}

test "recordFileHint keeps bounded file activity" {
    const allocator = std.testing.allocator;
    var state = WorkspaceState{
        .workspace_id = try allocator.dupe(u8, "dev"),
        .messages = try allocator.alloc(types.Message, 0),
        .file_hints = &.{},
    };
    defer state.deinit(allocator);

    try recordFileHint(&state, allocator, "read", "src/main.zig");
    try std.testing.expectEqual(@as(usize, 1), state.file_hints.len);

    const hint = try buildMemoryHintMessageAlloc(allocator, &state);
    try std.testing.expect(hint != null);
    defer hint.?.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, hint.?.content, "src/main.zig") != null);
}

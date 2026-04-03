const std = @import("std");

pub const Request = struct {
    prompt: []const u8,
    messages: []Message,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,

    pub fn deinit(self: Request, allocator: std.mem.Allocator) void {
        allocator.free(self.prompt);
        for (self.messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(self.messages);
        if (self.provider) |provider| {
            allocator.free(provider);
        }
        if (self.model) |model| {
            allocator.free(model);
        }
    }
};

pub const Message = struct {
    role: []const u8,
    content: []const u8,

    pub fn deinit(self: Message, allocator: std.mem.Allocator) void {
        allocator.free(self.role);
        allocator.free(self.content);
    }
};

pub const Usage = struct {
    prompt_tokens: usize = 0,
    completion_tokens: usize = 0,
    total_tokens: usize = 0,
};

pub const Response = struct {
    id: ?[]const u8 = null,
    model: []const u8,
    output: []const u8,
    finish_reason: []const u8,
    success: bool,
    usage: Usage = .{},

    pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
        if (self.id) |id| {
            allocator.free(id);
        }
        allocator.free(self.model);
        allocator.free(self.output);
        allocator.free(self.finish_reason);
    }
};

pub fn normalizeProviderName(value: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(value, "ollama_qwen")) return "ollama_qwen";
    if (std.ascii.eqlIgnoreCase(value, "ollama")) return "ollama_qwen";
    if (std.ascii.eqlIgnoreCase(value, "qwen")) return "ollama_qwen";
    return null;
}

test "normalizeProviderName accepts Qwen aliases" {
    try std.testing.expectEqualStrings("ollama_qwen", normalizeProviderName("ollama_qwen").?);
    try std.testing.expectEqualStrings("ollama_qwen", normalizeProviderName("ollama").?);
    try std.testing.expectEqualStrings("ollama_qwen", normalizeProviderName("qwen").?);
    try std.testing.expect(normalizeProviderName("bedrock") == null);
}

pub const TaskType = enum {
    chat,
    reasoning,
};

pub const Provider = enum {
    ollama_qwen,
    openrouter,
    bedrock,

    pub fn parse(value: []const u8) ?Provider {
        if (std.ascii.eqlIgnoreCase(value, "ollama_qwen")) return .ollama_qwen;
        if (std.ascii.eqlIgnoreCase(value, "ollama")) return .ollama_qwen;
        if (std.ascii.eqlIgnoreCase(value, "qwen")) return .ollama_qwen;
        if (std.ascii.eqlIgnoreCase(value, "openrouter")) return .openrouter;
        if (std.ascii.eqlIgnoreCase(value, "bedrock")) return .bedrock;
        return null;
    }

    pub fn name(self: Provider) []const u8 {
        return switch (self) {
            .ollama_qwen => "ollama_qwen",
            .openrouter => "openrouter",
            .bedrock => "bedrock",
        };
    }
};

pub const Request = struct {
    prompt: []const u8,
    messages: []Message,
    provider: ?Provider = null,
    model: ?[]const u8 = null,
    task: TaskType = .chat,

    pub fn deinit(self: Request, allocator: std.mem.Allocator) void {
        allocator.free(self.prompt);
        for (self.messages) |message| {
            message.deinit(allocator);
        }
        allocator.free(self.messages);
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

const std = @import("std");

test "Provider.parse accepts canonical names and aliases" {
    try std.testing.expectEqual(.ollama_qwen, Provider.parse("ollama_qwen").?);
    try std.testing.expectEqual(.ollama_qwen, Provider.parse("ollama").?);
    try std.testing.expectEqual(.ollama_qwen, Provider.parse("qwen").?);
    try std.testing.expectEqual(.openrouter, Provider.parse("openrouter").?);
    try std.testing.expectEqual(.bedrock, Provider.parse("bedrock").?);
    try std.testing.expect(Provider.parse("unknown") == null);
}

test "Provider.name returns stable public values" {
    try std.testing.expectEqualStrings("ollama_qwen", Provider.ollama_qwen.name());
    try std.testing.expectEqualStrings("openrouter", Provider.openrouter.name());
    try std.testing.expectEqualStrings("bedrock", Provider.bedrock.name());
}

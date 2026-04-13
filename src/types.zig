const std = @import("std");

pub const Request = struct {
    prompt: []const u8,
    messages: []Message,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    stream: bool = false,
    think: ?bool = null,
    temperature: ?f64 = null,
    repeat_penalty: ?f64 = null,
    session_id: ?[]const u8 = null,
    tenant_id: ?[]const u8 = null,
    max_context_tokens: ?usize = null,
    tools: []Tool,
    tool_choice: ?[]const u8 = null,

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
        if (self.session_id) |session_id| {
            allocator.free(session_id);
        }
        if (self.tenant_id) |tenant_id| {
            allocator.free(tenant_id);
        }
        for (self.tools) |tool| {
            tool.deinit(allocator);
        }
        allocator.free(self.tools);
        if (self.tool_choice) |tool_choice| {
            allocator.free(tool_choice);
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

pub const Tool = struct {
    name: []const u8,
    description: []const u8,

    pub fn deinit(self: Tool, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
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
    if (std.ascii.eqlIgnoreCase(value, "openai")) return "openai";
    if (std.ascii.eqlIgnoreCase(value, "claude")) return "claude";
    if (std.ascii.eqlIgnoreCase(value, "anthropic")) return "claude";
    if (std.ascii.eqlIgnoreCase(value, "llama_cpp")) return "llama_cpp";
    if (std.ascii.eqlIgnoreCase(value, "llama.cpp")) return "llama_cpp";
    return null;
}

test "normalizeProviderName accepts Qwen aliases" {
    try std.testing.expectEqualStrings("ollama_qwen", normalizeProviderName("ollama_qwen").?);
    try std.testing.expectEqualStrings("ollama_qwen", normalizeProviderName("ollama").?);
    try std.testing.expectEqualStrings("ollama_qwen", normalizeProviderName("qwen").?);
    try std.testing.expectEqualStrings("openai", normalizeProviderName("openai").?);
    try std.testing.expectEqualStrings("claude", normalizeProviderName("anthropic").?);
    try std.testing.expectEqualStrings("llama_cpp", normalizeProviderName("llama.cpp").?);
    try std.testing.expect(normalizeProviderName("bedrock") == null);
}

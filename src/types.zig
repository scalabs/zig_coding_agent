//! Shared request/response model types used across core, backend, and providers.
const std = @import("std");

/// Normalized request passed from parsing to provider dispatch.
///
/// Ownership: all string fields and message slices are owned by the request.
pub const Request = struct {
    prompt: []const u8, // Last user prompt used by provider adapters expecting a single prompt.
    messages: []Message, // Full ordered chat history.
    provider: ?[]const u8 = null, // Optional per-request provider override.
    model: ?[]const u8 = null, // Optional per-request model override.

    /// Releases all owned request allocations.
    ///
    /// Args:
    /// - self: request containing owned buffers.
    /// - allocator: allocator that allocated all request-owned memory.
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

/// One chat message in conversation order.
pub const Message = struct {
    role: []const u8, // OpenAI-compatible role (system, user, assistant, tool).
    content: []const u8, // Plain UTF-8 message content.

    /// Releases owned role and content buffers.
    ///
    /// Args:
    /// - self: message containing owned role and content.
    /// - allocator: allocator used for message allocations.
    pub fn deinit(self: Message, allocator: std.mem.Allocator) void {
        allocator.free(self.role);
        allocator.free(self.content);
    }
};

/// OpenAI-style token usage totals.
pub const Usage = struct {
    prompt_tokens: usize = 0, // Tokens consumed by prompt/history.
    completion_tokens: usize = 0, // Tokens generated in the assistant reply.
    total_tokens: usize = 0, // prompt_tokens + completion_tokens.
};

/// Provider response normalized into one transport-independent shape.
pub const Response = struct {
    id: ?[]const u8 = null, // Provider completion ID when available.
    model: []const u8, // Model that produced the output.
    output: []const u8, // Assistant text or provider error message.
    finish_reason: []const u8, // OpenAI-compatible completion stop reason.
    success: bool, // false means output should be surfaced as provider error.
    usage: Usage = .{}, // Best-effort token accounting.

    /// Releases all owned response fields.
    ///
    /// Args:
    /// - self: response containing owned buffers.
    /// - allocator: allocator used for response allocations.
    pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
        if (self.id) |id| {
            allocator.free(id);
        }
        allocator.free(self.model);
        allocator.free(self.output);
        allocator.free(self.finish_reason);
    }
};

/// Maps accepted provider aliases to canonical provider IDs.
///
/// Args:
/// - value: provider name supplied by config or request.
///
/// Returns:
/// - ?[]const u8: canonical provider ID when recognized, null otherwise.
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

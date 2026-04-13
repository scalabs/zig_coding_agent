//! Zig Coding Agent - LLM routing and chat completion service
//!
//! Public API for the agent. Use this library by importing root and accessing
//! the public modules: backend, core, and config.
const std = @import("std");

// Re-export public modules.
pub const backend = @import("backend/api.zig");
pub const auth = @import("backend/auth.zig");
pub const session = @import("backend/session.zig");
pub const tools = @import("backend/tools.zig");
pub const core = @import("core/server.zig");
pub const config = @import("config.zig");
pub const types = @import("types.zig");

// Re-export common error types.
pub const ApiError = backend.errors.ApiError;

test "backend: chat request parsing" {
    _ = @import("backend/api.zig");
}

test "backend: auth and tool scaffolding" {
    _ = @import("backend/auth.zig");
    _ = @import("backend/tools.zig");
    _ = @import("backend/session.zig");
}

test "core: HTTP request parsing" {
    _ = @import("core/request.zig");
}

test "core: routing" {
    _ = @import("core/router.zig");
}

test "types: normalization" {
    _ = @import("types.zig");
}

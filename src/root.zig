//! Public package surface for the Zig Coding Agent.
//!
//! Keep imports stable here so dependents can use `@import("zig_coding_agent")`
//! without depending on internal file layout.
// Re-export public modules.
pub const backend = @import("backend/api.zig");
pub const core = @import("core/server.zig");
pub const config = @import("config.zig");
pub const types = @import("types.zig");

// Re-export common error types.
pub const ApiError = backend.errors.ApiError;

test "backend: chat request parsing" {
    _ = @import("backend/api.zig");
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

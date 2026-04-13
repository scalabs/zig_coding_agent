//! Shared API error model and constructors for HTTP responses.
const std = @import("std");

/// Unified error type used by transport and validation layers.
pub const ApiError = struct {
    status_code: u16, // HTTP response status.
    message: []const u8, // Human-readable client-facing error text.
    error_type: []const u8, // OpenAI-style category (invalid_request_error, provider_error).
    param: ?[]const u8 = null, // Optional request field tied to the error.
    code: ?[]const u8 = null, // Optional machine-readable code for client branching.
};

/// Creates a validation error with HTTP 400 status.
///
/// Args:
/// - message: user-facing validation detail.
/// - param: optional request parameter name.
/// - code: optional stable code for client branching.
///
/// Returns:
/// - ApiError: populated invalid_request_error payload.
pub fn validationError(
    message: []const u8,
    param: ?[]const u8,
    code: ?[]const u8,
) ApiError {
    return .{
        .status_code = 400,
        .message = message,
        .error_type = "invalid_request_error",
        .param = param,
        .code = code,
    };
}

/// Creates a provider transport/runtime error with HTTP 502 status.
///
/// Args:
/// - message: user-facing provider failure message.
/// - code: optional stable provider error code.
///
/// Returns:
/// - ApiError: populated provider_error payload.
pub fn providerError(
    message: []const u8,
    code: ?[]const u8,
) ApiError {
    return .{
        .status_code = 502,
        .message = message,
        .error_type = "provider_error",
        .param = null,
        .code = code,
    };
}

/// Creates an HTTP parsing/request-shape error using validation semantics.
///
/// Args:
/// - message: parsing failure detail.
/// - code: optional stable parse error code.
///
/// Returns:
/// - ApiError: populated invalid_request_error payload.
pub fn httpError(message: []const u8, code: ?[]const u8) ApiError {
    return validationError(message, null, code);
}

/// Creates a not-found route error with HTTP 404 status.
///
/// Returns:
/// - ApiError: standardized not_found response payload.
pub fn notFoundError() ApiError {
    return .{
        .status_code = 404,
        .message = "Route not found",
        .error_type = "invalid_request_error",
        .param = null,
        .code = "not_found",
    };
}

/// Creates a request-too-large error with HTTP 413 status.
///
/// Returns:
/// - ApiError: standardized request_too_large payload.
pub fn payloadTooLargeError() ApiError {
    return .{
        .status_code = 413,
        .message = "Request body is too large",
        .error_type = "invalid_request_error",
        .param = null,
        .code = "request_too_large",
    };
}

/// Parse helper result used by request validation callers.
pub const ParseChatRequestResult = union(enum) {
    ok: void,
    err: ApiError,
};

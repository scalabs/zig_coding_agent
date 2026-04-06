const std = @import("std");

/// Unified error types for API responses
pub const ApiError = struct {
    status_code: u16,
    message: []const u8,
    error_type: []const u8,
    param: ?[]const u8 = null,
    code: ?[]const u8 = null,
};

/// Validation error - 400 Bad Request
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

/// Provider error - 502 Bad Gateway
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

/// HTTP parsing error - 400 Bad Request
pub fn httpError(message: []const u8, code: ?[]const u8) ApiError {
    return validationError(message, null, code);
}

/// Route not found error - 404 Not Found
pub fn notFoundError() ApiError {
    return .{
        .status_code = 404,
        .message = "Route not found",
        .error_type = "invalid_request_error",
        .param = null,
        .code = "not_found",
    };
}

/// Request payload too large - 413 Payload Too Large
pub fn payloadTooLargeError() ApiError {
    return .{
        .status_code = 413,
        .message = "Request body is too large",
        .error_type = "invalid_request_error",
        .param = null,
        .code = "request_too_large",
    };
}

pub const ParseChatRequestResult = union(enum) {
    ok: void,
    err: ApiError,
};

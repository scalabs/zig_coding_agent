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

/// Classifies provider failures into a stable API error shape.
///
/// This keeps client-facing error semantics predictable even when upstream
/// providers return different payloads/status conventions.
pub fn providerFailureFromDetail(
    provider: []const u8,
    detail: []const u8,
) ApiError {
    _ = provider;

    if (containsIgnoreCase(detail, "api key") and containsIgnoreCase(detail, "not configured")) {
        return .{
            .status_code = 500,
            .message = "Provider credentials are not configured on the server",
            .error_type = "provider_error",
            .param = null,
            .code = "provider_not_configured",
        };
    }

    if (containsIgnoreCase(detail, "timeout")) {
        return .{
            .status_code = 504,
            .message = "Provider request timed out",
            .error_type = "provider_error",
            .param = null,
            .code = "provider_timeout",
        };
    }

    if (containsIgnoreCase(detail, "not a json") or containsIgnoreCase(detail, "missing") or containsIgnoreCase(detail, "invalid")) {
        return .{
            .status_code = 502,
            .message = "Provider returned an invalid response payload",
            .error_type = "provider_error",
            .param = null,
            .code = "provider_invalid_response",
        };
    }

    if (parseHttpStatus(detail)) |status| {
        if (status == 401 or status == 403) {
            return .{
                .status_code = 502,
                .message = "Provider authentication failed",
                .error_type = "provider_error",
                .param = null,
                .code = "provider_auth_failed",
            };
        }

        if (status == 404 or containsIgnoreCase(detail, "not_found")) {
            return .{
                .status_code = 502,
                .message = "Requested provider model or endpoint was not found",
                .error_type = "provider_error",
                .param = null,
                .code = "provider_not_found",
            };
        }

        if (status == 429) {
            return .{
                .status_code = 503,
                .message = "Provider is rate limiting requests",
                .error_type = "provider_error",
                .param = null,
                .code = "provider_rate_limited",
            };
        }

        if (status == 408) {
            return .{
                .status_code = 504,
                .message = "Provider request timed out",
                .error_type = "provider_error",
                .param = null,
                .code = "provider_timeout",
            };
        }

        if (status >= 500 and status <= 599) {
            return .{
                .status_code = 502,
                .message = "Provider upstream error",
                .error_type = "provider_error",
                .param = null,
                .code = "provider_upstream_error",
            };
        }

        if (status >= 400 and status <= 499) {
            return .{
                .status_code = 502,
                .message = "Provider rejected the request",
                .error_type = "provider_error",
                .param = null,
                .code = "provider_rejected_request",
            };
        }
    }

    return providerError("Provider request failed", "provider_error");
}

/// Maps transport/runtime failures where no upstream HTTP response was decoded.
pub fn providerTransportError(transport_error_name: []const u8) ApiError {
    if (containsIgnoreCase(transport_error_name, "timeout")) {
        return .{
            .status_code = 504,
            .message = "Provider request timed out",
            .error_type = "provider_error",
            .param = null,
            .code = "provider_timeout",
        };
    }

    return .{
        .status_code = 502,
        .message = "Provider transport failure",
        .error_type = "provider_error",
        .param = null,
        .code = "provider_transport_error",
    };
}

fn parseHttpStatus(detail: []const u8) ?u16 {
    const marker = "HTTP ";
    const start = std.mem.indexOf(u8, detail, marker) orelse return null;
    const idx = start + marker.len;
    var end = idx;

    while (end < detail.len and std.ascii.isDigit(detail[end])) : (end += 1) {}
    if (end == idx) return null;

    return std.fmt.parseInt(u16, detail[idx..end], 10) catch null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) {
            return true;
        }
    }
    return false;
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

/// Creates a request-timeout error with HTTP 408 status.
pub fn requestTimeoutError() ApiError {
    return .{
        .status_code = 408,
        .message = "Request timed out while reading body",
        .error_type = "invalid_request_error",
        .param = null,
        .code = "request_timeout",
    };
}

/// Parse helper result used by request validation callers.
pub const ParseChatRequestResult = union(enum) {
    ok: void,
    err: ApiError,
};

test "providerFailureFromDetail maps rate limits" {
    const mapped = providerFailureFromDetail("openai", "OpenAI returned HTTP 429");
    try std.testing.expectEqual(@as(u16, 503), mapped.status_code);
    try std.testing.expectEqualStrings("provider_rate_limited", mapped.code.?);
}

test "providerFailureFromDetail maps missing key configuration" {
    const mapped = providerFailureFromDetail("claude", "Claude API key is not configured on the server");
    try std.testing.expectEqual(@as(u16, 500), mapped.status_code);
    try std.testing.expectEqualStrings("provider_not_configured", mapped.code.?);
}

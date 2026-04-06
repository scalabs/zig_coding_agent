const std = @import("std");
const errors = @import("../backend/errors.zig");

/// Parse HTTP Content-Length header from raw request
pub fn parseContentLength(headers: []const u8) !usize {
    var lines = std.mem.splitScalar(u8, headers, '\n');
    _ = lines.next() orelse return error.InvalidHttpRequest;

    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0) continue;

        const separator_index = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const header_name = std.mem.trim(u8, line[0..separator_index], " ");
        const header_value = std.mem.trim(u8, line[separator_index + 1 ..], " ");

        if (std.ascii.eqlIgnoreCase(header_name, "Content-Length")) {
            return std.fmt.parseInt(usize, header_value, 10) catch {
                return error.InvalidContentLength;
            };
        }
    }

    return error.MissingContentLength;
}

/// Find message body in HTTP request (after headers)
pub fn findBody(request_raw: []const u8) ?[]const u8 {
    const separator = "\r\n\r\n";
    const index = std.mem.indexOf(u8, request_raw, separator) orelse return null;
    return request_raw[index + separator.len ..];
}

/// Extract the first line of an HTTP request
pub fn firstRequestLine(request_raw: []const u8) []const u8 {
    const request_line_end = std.mem.indexOf(u8, request_raw, "\r\n") orelse request_raw.len;
    return request_raw[0..request_line_end];
}

pub const ReadHttpRequestError = error{
    RequestTooLarge,
    HeadersTooLarge,
    InvalidHttpRequest,
    MissingContentLength,
    InvalidContentLength,
    IncompleteRequestBody,
};

/// Read complete HTTP request from connection
pub fn readHttpRequest(
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
) ![]u8 {
    const max_request_size = 1024 * 1024;
    const max_header_size = 16 * 1024;

    var request = std.ArrayList(u8){};
    errdefer request.deinit(allocator);

    var chunk: [4096]u8 = undefined;
    var header_end: ?usize = null;
    var total_length: ?usize = null;

    while (true) {
        const bytes_read = try connection.stream.read(&chunk);
        if (bytes_read == 0) break;

        if (request.items.len + bytes_read > max_request_size) {
            return error.RequestTooLarge;
        }

        try request.appendSlice(allocator, chunk[0..bytes_read]);

        if (header_end == null) {
            if (std.mem.indexOf(u8, request.items, "\r\n\r\n")) |index| {
                header_end = index + 4;

                const content_length = try parseContentLength(request.items[0..index]);
                const required_length = header_end.? + content_length;
                if (required_length > max_request_size) {
                    return error.RequestTooLarge;
                }

                total_length = required_length;
            } else if (request.items.len > max_header_size) {
                return error.HeadersTooLarge;
            }
        }

        if (total_length) |required_length| {
            if (request.items.len >= required_length) break;
        }
    }

    if (request.items.len == 0) {
        return try allocator.alloc(u8, 0);
    }

    if (header_end == null or total_length == null) {
        return error.InvalidHttpRequest;
    }

    if (request.items.len < total_length.?) {
        return error.IncompleteRequestBody;
    }

    request.items.len = total_length.?;
    return try request.toOwnedSlice(allocator);
}

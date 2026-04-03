const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const base_url = try getEnvOrDefault(allocator, "OLLAMA_BASE_URL", "http://127.0.0.1:11434");
    defer allocator.free(base_url);

    const model = try getEnvOrDefault(allocator, "OLLAMA_MODEL", "qwen:7b");
    defer allocator.free(model);

    const uri_text = try buildChatUrl(allocator, base_url);
    defer allocator.free(uri_text);

    const uri = try std.Uri.parse(uri_text);

    const request_body = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "model": "{s}",
        \\  "messages": [
        \\    {{ "role": "user", "content": "Say hello from Zig" }}
        \\  ],
        \\  "stream": false
        \\}}
    , .{model});
    defer allocator.free(request_body);

    var body = std.Io.Writer.Allocating.init(allocator);
    defer body.deinit();

    const headers = &[_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
    };

    const result = try client.fetch(.{
        .location = .{ .uri = uri },
        .method = .POST,
        .extra_headers = headers,
        .payload = request_body,
        .response_writer = &body.writer,
    });

    if (result.status != .ok) {
        std.debug.print("HTTP status: {}\n", .{result.status});
        return error.BadStatus;
    }

    std.debug.print("{s}\n", .{body.written()});
}

fn getEnvOrDefault(
    allocator: std.mem.Allocator,
    key: []const u8,
    default_value: []const u8,
) ![]u8 {
    return std.process.getEnvVarOwned(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, default_value),
        else => err,
    };
}

fn buildChatUrl(
    allocator: std.mem.Allocator,
    base_url: []const u8,
) ![]u8 {
    if (std.mem.endsWith(u8, base_url, "/")) {
        return try std.fmt.allocPrint(allocator, "{s}api/chat", .{base_url});
    }

    return try std.fmt.allocPrint(allocator, "{s}/api/chat", .{base_url});
}

const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse("http://127.0.0.1:11434/api/chat");

    const request_body =
        \\{
        \\  "model": "qwen:7b",
        \\  "messages": [
        \\    { "role": "user", "content": "Say hello from Zig" }
        \\  ],
        \\  "stream": false
        \\}
    ;

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

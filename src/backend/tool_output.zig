//! Tool output offloading for large tool results.
//!
//! When tool output exceeds a configured byte threshold, the full payload is
//! written to disk and a compact head/tail summary is returned for context.
const std = @import("std");
const config = @import("../config.zig");

const head_tail_preview_bytes = 512;

pub fn maybeOffloadToolOutputAlloc(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    request_id: []const u8,
    tool_name: []const u8,
    output: []const u8,
) ![]u8 {
    if (app_config.tool_output_offload_bytes == 0) {
        return try allocator.dupe(u8, output);
    }
    if (output.len <= app_config.tool_output_offload_bytes) {
        return try allocator.dupe(u8, output);
    }

    const offload_dir = try std.fmt.allocPrint(allocator, "{s}/tool_outputs", .{app_config.session_store_path});
    defer allocator.free(offload_dir);

    std.fs.cwd().makePath(offload_dir) catch {};

    var safe_tool_name_buf: [64]u8 = undefined;
    const safe_tool_name = sanitizePathComponent(tool_name, &safe_tool_name_buf);
    const offload_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}_{s}.txt",
        .{ offload_dir, request_id, safe_tool_name },
    );
    defer allocator.free(offload_path);

    const file = std.fs.cwd().createFile(offload_path, .{}) catch {
        return try allocator.dupe(u8, output);
    };
    defer file.close();
    file.writeAll(output) catch {
        return try allocator.dupe(u8, output);
    };

    const head_len = @min(head_tail_preview_bytes, output.len);
    const tail_len = @min(head_tail_preview_bytes, output.len - head_len);
    const tail_start = output.len - tail_len;

    return try std.fmt.allocPrint(
        allocator,
        "tool_output_offloaded=true\nfull_bytes={d}\noffload_path={s}\n--- head ---\n{s}\n--- tail ---\n{s}",
        .{
            output.len,
            offload_path,
            output[0..head_len],
            output[tail_start..],
        },
    );
}

fn sanitizePathComponent(name: []const u8, out: *[64]u8) []const u8 {
    var len: usize = 0;
    for (name) |c| {
        if (len >= out.len) break;
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {
                out.*[len] = c;
                len += 1;
            },
            else => {},
        }
    }
    if (len == 0) return "tool";
    return out[0..len];
}

test "maybeOffloadToolOutputAlloc keeps small output inline" {
    const allocator = std.testing.allocator;
    var cfg = try @import("../tools/command_exec.zig").buildTestConfig(allocator, false);
    defer cfg.deinit(allocator);
    cfg.tool_output_offload_bytes = 64;

    const output = try maybeOffloadToolOutputAlloc(allocator, &cfg, "req-1", "echo", "small");
    defer allocator.free(output);

    try std.testing.expectEqualStrings("small", output);
}

test "maybeOffloadToolOutputAlloc offloads large output with preview" {
    const allocator = std.testing.allocator;
    var cfg = try @import("../tools/command_exec.zig").buildTestConfig(allocator, false);
    defer cfg.deinit(allocator);
    cfg.tool_output_offload_bytes = 32;

    const large = try allocator.alloc(u8, 128);
    defer allocator.free(large);
    @memset(large, 'x');

    const output = try maybeOffloadToolOutputAlloc(allocator, &cfg, "req-offload", "echo", large);
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "tool_output_offloaded=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "offload_path=") != null);
}

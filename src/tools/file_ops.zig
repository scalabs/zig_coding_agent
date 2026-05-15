const std = @import("std");
const config = @import("../config.zig");
const types = @import("../types.zig");

pub const Op = enum { read, write, search };

pub fn execute(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    request: types.Request,
    op: Op,
) !types.Response {
    const tool_name: []const u8 = switch (op) {
        .read => "file_read",
        .write => "file_write",
        .search => "file_search",
    };

    const prompt = std.mem.trim(u8, request.prompt, " \t\r\n");
    if (prompt.len == 0) {
        return try makeToolResponse(
            allocator,
            tool_name,
            try std.fmt.allocPrint(allocator, "DEBUG_TOOL_ERROR\ntool={s}\nmessage=empty prompt", .{tool_name}),
        );
    }

    return switch (op) {
        .read => executeRead(allocator, app_config, tool_name, prompt),
        .write => executeWrite(allocator, app_config, tool_name, request, prompt),
        .search => executeSearch(allocator, app_config, tool_name, prompt),
    };
}

fn executeRead(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    tool_name: []const u8,
    prompt: []const u8,
) !types.Response {
    const path_raw = parseSingleArgAfterPrefix(prompt, "read ") orelse
        parseSingleArgAfterPrefix(prompt, "file_read ") orelse
        parseSingleArgAfterPrefix(prompt, "exists ") orelse
        parseSingleArgAfterPrefix(prompt, "file_exists ") orelse
        parseSingleArgAfterPrefix(prompt, "open ") orelse
        prompt;

    const rel_path = validateRelativePath(path_raw) catch |err| {
        return try makeToolResponse(
            allocator,
            tool_name,
            try std.fmt.allocPrint(
                allocator,
                "DEBUG_TOOL_ERROR\ntool={s}\nvalidation_error={s}\nmessage=invalid path",
                .{ tool_name, @errorName(err) },
            ),
        );
    };

    const tmp_rel_path = try prefixTmpPathAlloc(allocator, rel_path);
    defer allocator.free(tmp_rel_path);

    const start_ms = std.time.milliTimestamp();
    var file = std.fs.cwd().openFile(tmp_rel_path, .{}) catch |err| {
        return try makeToolResponse(
            allocator,
            tool_name,
            try std.fmt.allocPrint(allocator, "DEBUG_TOOL_ERROR\ntool={s}\nopen_error={s}\npath={s}", .{ tool_name, @errorName(err), tmp_rel_path }),
        );
    };
    defer file.close();

    const bytes = file.readToEndAlloc(allocator, app_config.tool_exec_max_output_bytes) catch |err| {
        return try makeToolResponse(
            allocator,
            tool_name,
            try std.fmt.allocPrint(allocator, "DEBUG_TOOL_ERROR\ntool={s}\nread_error={s}\npath={s}", .{ tool_name, @errorName(err), tmp_rel_path }),
        );
    };
    defer allocator.free(bytes);

    const end_ms = std.time.milliTimestamp();
    const duration_ms: u64 = if (end_ms >= start_ms) @as(u64, @intCast(end_ms - start_ms)) else 0;

    const out = try std.fmt.allocPrint(
        allocator,
        "DEBUG_TOOL_OK\ntool={s}\npath={s}\nduration_ms={d}\nmax_bytes={d}\n--- content ---\n{s}",
        .{ tool_name, tmp_rel_path, duration_ms, app_config.tool_exec_max_output_bytes, bytes },
    );
    return try makeToolResponse(allocator, tool_name, out);
}

fn executeWrite(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    tool_name: []const u8,
    request: types.Request,
    prompt: []const u8,
) !types.Response {
    const parsed = parseWritePrompt(allocator, prompt) catch blk: {
        const inferred_path = inferWriteFilenameFromPromptAlloc(allocator, prompt) orelse break :blk null;
        errdefer allocator.free(inferred_path);

        const inferred_content = extractLastFencedCodeBlockAlloc(allocator, request.messages) orelse {
            allocator.free(inferred_path);
            break :blk null;
        };
        errdefer allocator.free(inferred_content);

        break :blk ParsedWrite{
            .path = inferred_path,
            .content = inferred_content,
        };
    } orelse {
        return try makeToolResponse(
            allocator,
            tool_name,
            try std.fmt.allocPrint(
                allocator,
                "DEBUG_TOOL_ERROR\ntool={s}\nmessage=could not parse write request; use `write <path>` + fenced code block, or say `save the script as count.py` after providing a fenced code block",
                .{tool_name},
            ),
        );
    };
    defer allocator.free(parsed.path);
    defer allocator.free(parsed.content);

    const rel_path = validateRelativePath(parsed.path) catch |err| {
        return try makeToolResponse(
            allocator,
            tool_name,
            try std.fmt.allocPrint(allocator, "DEBUG_TOOL_ERROR\ntool={s}\nvalidation_error={s}\nmessage=invalid path", .{ tool_name, @errorName(err) }),
        );
    };

    const tmp_rel_path = try prefixTmpPathAlloc(allocator, rel_path);
    defer allocator.free(tmp_rel_path);

    if (parsed.content.len > app_config.tool_exec_max_output_bytes) {
        return try makeToolResponse(
            allocator,
            tool_name,
            try std.fmt.allocPrint(
                allocator,
                "DEBUG_TOOL_ERROR\ntool={s}\nmessage=content too large\ncontent_bytes={d}\nmax_bytes={d}",
                .{ tool_name, parsed.content.len, app_config.tool_exec_max_output_bytes },
            ),
        );
    }

    const start_ms = std.time.milliTimestamp();

    if (std.fs.path.dirname(tmp_rel_path)) |dir_name| {
        std.fs.cwd().makePath(dir_name) catch |err| {
            return try makeToolResponse(
                allocator,
                tool_name,
                try std.fmt.allocPrint(allocator, "DEBUG_TOOL_ERROR\ntool={s}\nmkdir_error={s}\ndir={s}", .{ tool_name, @errorName(err), dir_name }),
            );
        };
    }

    var file = std.fs.cwd().createFile(tmp_rel_path, .{ .truncate = true }) catch |err| {
        return try makeToolResponse(
            allocator,
            tool_name,
            try std.fmt.allocPrint(allocator, "DEBUG_TOOL_ERROR\ntool={s}\ncreate_error={s}\npath={s}", .{ tool_name, @errorName(err), tmp_rel_path }),
        );
    };
    defer file.close();

    file.writeAll(parsed.content) catch |err| {
        return try makeToolResponse(
            allocator,
            tool_name,
            try std.fmt.allocPrint(allocator, "DEBUG_TOOL_ERROR\ntool={s}\nwrite_error={s}\npath={s}", .{ tool_name, @errorName(err), tmp_rel_path }),
        );
    };

    const end_ms = std.time.milliTimestamp();
    const duration_ms: u64 = if (end_ms >= start_ms) @as(u64, @intCast(end_ms - start_ms)) else 0;

    const out = try std.fmt.allocPrint(
        allocator,
        "DEBUG_TOOL_OK\ntool={s}\npath={s}\nbytes_written={d}\nduration_ms={d}\n--- content ---\n{s}",
        .{ tool_name, tmp_rel_path, parsed.content.len, duration_ms, parsed.content },
    );
    return try makeToolResponse(allocator, tool_name, out);
}

fn executeSearch(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    tool_name: []const u8,
    prompt: []const u8,
) !types.Response {
    const parsed = parseSearchPrompt(allocator, prompt) catch |err| {
        return try makeToolResponse(
            allocator,
            tool_name,
            try std.fmt.allocPrint(
                allocator,
                "DEBUG_TOOL_ERROR\ntool={s}\nparse_error={s}\nmessage=expected: search <pattern> [in <dir>]",
                .{ tool_name, @errorName(err) },
            ),
        );
    };
    defer allocator.free(parsed.pattern);
    defer allocator.free(parsed.dir);

    const rel_dir = validateRelativePath(parsed.dir) catch |err| {
        return try makeToolResponse(
            allocator,
            tool_name,
            try std.fmt.allocPrint(allocator, "DEBUG_TOOL_ERROR\ntool={s}\nvalidation_error={s}\nmessage=invalid dir", .{ tool_name, @errorName(err) }),
        );
    };

    const tmp_rel_dir = try prefixTmpPathAlloc(allocator, rel_dir);
    defer allocator.free(tmp_rel_dir);

    const start_ms = std.time.milliTimestamp();

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try out.writer(allocator).print(
        "DEBUG_TOOL_OK\ntool={s}\ndir={s}\npattern={s}\nmax_bytes={d}\n--- matches ---\n",
        .{ tool_name, tmp_rel_dir, parsed.pattern, app_config.tool_exec_max_output_bytes },
    );

    var bytes_budget: usize = app_config.tool_exec_max_output_bytes;
    if (out.items.len < bytes_budget) bytes_budget -= out.items.len else bytes_budget = 0;

    var matches: usize = 0;
    var files_scanned: usize = 0;
    const max_files: usize = 500;

    var dir = std.fs.cwd().openDir(tmp_rel_dir, .{ .iterate = true }) catch |err| {
        return try makeToolResponse(
            allocator,
            tool_name,
            try std.fmt.allocPrint(allocator, "DEBUG_TOOL_ERROR\ntool={s}\nopen_dir_error={s}\ndir={s}", .{ tool_name, @errorName(err), tmp_rel_dir }),
        );
    };
    defer dir.close();

    var walker = dir.walk(allocator) catch |err| return err;
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (files_scanned >= max_files) break;
        if (entry.kind != .file) continue;
        files_scanned += 1;

        const path_in_dir = entry.path;
        if (std.mem.endsWith(u8, path_in_dir, ".exe") or std.mem.endsWith(u8, path_in_dir, ".dll")) continue;

        var f = dir.openFile(path_in_dir, .{}) catch continue;
        defer f.close();

        const bytes = f.readToEndAlloc(allocator, 64 * 1024) catch continue;
        defer allocator.free(bytes);

        if (std.mem.indexOf(u8, bytes, parsed.pattern) == null) continue;
        matches += 1;

        const line = try std.fmt.allocPrint(allocator, "{s}\n", .{path_in_dir});
        defer allocator.free(line);

        if (line.len > bytes_budget) break;
        try out.appendSlice(allocator, line);
        bytes_budget -= line.len;
        if (bytes_budget == 0) break;
    }

    const end_ms = std.time.milliTimestamp();
    const duration_ms: u64 = if (end_ms >= start_ms) @as(u64, @intCast(end_ms - start_ms)) else 0;
    try out.writer(allocator).print("\nfiles_scanned={d}\nmatches={d}\nduration_ms={d}\n", .{ files_scanned, matches, duration_ms });

    return try makeToolResponse(allocator, tool_name, try out.toOwnedSlice(allocator));
}

fn inferWriteFilenameFromPromptAlloc(allocator: std.mem.Allocator, prompt: []const u8) ?[]u8 {
    const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    if (trimmed.len == 0) return null;

    var it = std.mem.tokenizeAny(u8, trimmed, " \t\r\n\"'`()[]{}<>");
    var last_match: ?[]const u8 = null;
    while (it.next()) |tok| {
        if (tok.len < 4) continue;
        if (!isSupportedWriteFilename(tok)) continue;
        last_match = tok;
    }

    if (last_match) |m| {
        return allocator.dupe(u8, m) catch null;
    }
    return null;
}

fn isSupportedWriteFilename(path: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, ".py") or
        std.ascii.endsWithIgnoreCase(path, ".cpp") or
        std.ascii.endsWithIgnoreCase(path, ".cc") or
        std.ascii.endsWithIgnoreCase(path, ".cxx") or
        std.ascii.endsWithIgnoreCase(path, ".c") or
        std.ascii.endsWithIgnoreCase(path, ".h") or
        std.ascii.endsWithIgnoreCase(path, ".hpp") or
        std.ascii.endsWithIgnoreCase(path, ".js") or
        std.ascii.endsWithIgnoreCase(path, ".ts") or
        std.ascii.endsWithIgnoreCase(path, ".zig");
}

fn extractLastFencedCodeBlockAlloc(allocator: std.mem.Allocator, messages: []const types.Message) ?[]u8 {
    var i: usize = messages.len;
    while (i > 0) {
        i -= 1;
        const msg = messages[i];
        if (!std.ascii.eqlIgnoreCase(msg.role, "assistant")) continue;

        const content = msg.content;
        const fence_end = std.mem.lastIndexOf(u8, content, "```") orelse continue;
        const before_end = content[0..fence_end];
        const fence_start = std.mem.lastIndexOf(u8, before_end, "```") orelse continue;

        const after_start = content[fence_start + 3 ..];
        const nl = std.mem.indexOfScalar(u8, after_start, '\n') orelse continue;
        const after_lang = after_start[nl + 1 ..];
        const end = std.mem.indexOf(u8, after_lang, "```") orelse continue;

        const inner = std.mem.trim(u8, after_lang[0..end], "\r\n");
        if (inner.len == 0) continue;
        return allocator.dupe(u8, inner) catch null;
    }
    return null;
}

const ParsedWrite = struct {
    path: []u8,
    content: []u8,
};

fn parseWritePrompt(allocator: std.mem.Allocator, prompt: []const u8) !ParsedWrite {
    var trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    if (!std.ascii.startsWithIgnoreCase(trimmed, "write ")) return error.BadFormat;
    trimmed = trimmed["write ".len..];
    trimmed = std.mem.trimLeft(u8, trimmed, " \t");
    if (trimmed.len == 0) return error.BadFormat;

    const fence_idx = std.mem.indexOf(u8, trimmed, "```") orelse return error.BadFormat;
    const path_part = std.mem.trim(u8, trimmed[0..fence_idx], " \t\r\n\"'");
    if (path_part.len == 0) return error.BadFormat;

    const fence_start = fence_idx;
    const after_fence = trimmed[fence_start + 3 ..];
    const newline_idx = std.mem.indexOfScalar(u8, after_fence, '\n') orelse return error.BadFormat;
    const after_lang = after_fence[newline_idx + 1 ..];
    const fence_end = std.mem.indexOf(u8, after_lang, "```") orelse return error.BadFormat;
    const content_part = after_lang[0..fence_end];

    return .{
        .path = try allocator.dupe(u8, path_part),
        .content = try allocator.dupe(u8, content_part),
    };
}

const ParsedSearch = struct {
    pattern: []u8,
    dir: []u8,
};

fn parseSearchPrompt(allocator: std.mem.Allocator, prompt: []const u8) !ParsedSearch {
    var trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    if (std.ascii.startsWithIgnoreCase(trimmed, "search ")) {
        trimmed = trimmed["search ".len..];
    } else if (std.ascii.startsWithIgnoreCase(trimmed, "file_search ")) {
        trimmed = trimmed["file_search ".len..];
    } else {
        return error.BadFormat;
    }

    trimmed = std.mem.trimLeft(u8, trimmed, " \t");
    if (trimmed.len == 0) return error.BadFormat;

    var dir_value: []const u8 = ".";
    var pattern_value: []const u8 = trimmed;

    if (indexOfIgnoreCase(trimmed, " in ")) |idx| {
        pattern_value = std.mem.trim(u8, trimmed[0..idx], " \t\r\n\"'");
        dir_value = std.mem.trim(u8, trimmed[idx + 4 ..], " \t\r\n\"'");
    } else {
        pattern_value = std.mem.trim(u8, pattern_value, " \t\r\n\"'");
    }

    if (pattern_value.len == 0) return error.BadFormat;
    if (dir_value.len == 0) dir_value = ".";

    return .{
        .pattern = try allocator.dupe(u8, pattern_value),
        .dir = try allocator.dupe(u8, dir_value),
    };
}

fn parseSingleArgAfterPrefix(text: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.ascii.startsWithIgnoreCase(text, prefix)) return null;
    return std.mem.trim(u8, text[prefix.len..], " \t\r\n\"'");
}

fn prefixTmpPathAlloc(allocator: std.mem.Allocator, rel_path: []const u8) ![]u8 {
    // All tool file IO is sandboxed under `tmp/` so generated artifacts don't
    // spill into the repo root.
    if (std.ascii.eqlIgnoreCase(rel_path, ".")) {
        return allocator.dupe(u8, "tmp");
    }

    if (std.ascii.startsWithIgnoreCase(rel_path, "tmp")) {
        if (rel_path.len == 3) return allocator.dupe(u8, rel_path);
        const next = rel_path[3];
        if (next == '/' or next == std.fs.path.sep) return allocator.dupe(u8, rel_path);
    }

    return std.fmt.allocPrint(allocator, "tmp{c}{s}", .{ std.fs.path.sep, rel_path });
}

const PathValidationError = error{
    EmptyPath,
    AbsolutePath,
    ParentTraversal,
    ContainsNul,
};

fn validateRelativePath(path_raw: []const u8) ![]const u8 {
    const p = std.mem.trim(u8, path_raw, " \t\r\n\"'");
    if (p.len == 0) return error.EmptyPath;
    if (std.mem.indexOfScalar(u8, p, 0) != null) return error.ContainsNul;
    if (std.fs.path.isAbsolute(p)) return error.AbsolutePath;

    var it = std.mem.splitScalar(u8, p, std.fs.path.sep);
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return error.ParentTraversal;
    }

    return p;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn makeToolResponse(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    output: []u8,
) !types.Response {
    errdefer allocator.free(output);
    const model_name = try std.fmt.allocPrint(allocator, "debug-tools/{s}", .{tool_name});
    errdefer allocator.free(model_name);
    return .{
        .id = null,
        .model = model_name,
        .output = output,
        .finish_reason = try allocator.dupe(u8, "tool"),
        .success = true,
        .usage = .{},
    };
}

test "inferWriteFilenameFromPromptAlloc supports C++ filenames" {
    const allocator = std.testing.allocator;
    const path = inferWriteFilenameFromPromptAlloc(allocator, "file_write app.cpp") orelse return error.ExpectedFilename;
    defer allocator.free(path);

    try std.testing.expectEqualStrings("app.cpp", path);
}

test "isSupportedWriteFilename keeps Python inference" {
    try std.testing.expect(isSupportedWriteFilename("count.py"));
    try std.testing.expect(!isSupportedWriteFilename("notes.txt"));
}


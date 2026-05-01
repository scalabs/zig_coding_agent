const std = @import("std");
const config = @import("../config.zig");
const types = @import("../types.zig");

pub const ShellFlavor = enum {
    cmd,
    bash,
};

const max_command_len: usize = 1024;

const CommandValidationError = error{
    EmptyCommand,
    CommandTooLong,
    UnsafeCharacter,
    DangerousCommand,
    DangerousPattern,
};

const PipeCapture = struct {
    bytes: []u8 = &.{},
    err_name: ?[]const u8 = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub fn execute(
    allocator: std.mem.Allocator,
    app_config: *const config.Config,
    request: types.Request,
    flavor: ShellFlavor,
) !types.Response {
    const tool_name = switch (flavor) {
        .cmd => "cmd",
        .bash => "bash",
    };

    if (!app_config.tool_exec_enabled) {
        return try makeToolResponse(
            allocator,
            tool_name,
            try std.fmt.allocPrint(
                allocator,
                "DEBUG_TOOL_ERROR\ntool={s}\nmessage=command execution disabled\nset LLM_ROUTER_TOOL_EXEC_ENABLED=1 to enable",
                .{tool_name},
            ),
        );
    }

    const prompt = std.mem.trim(u8, request.prompt, " \t\r\n");
    if (prompt.len == 0) {
        return try makeToolResponse(
            allocator,
            tool_name,
            try std.fmt.allocPrint(
                allocator,
                "DEBUG_TOOL_ERROR\ntool={s}\nmessage=empty command prompt",
                .{tool_name},
            ),
        );
    }

    const command = blk: {
        if (looksLikeCommandPrompt(prompt)) {
            break :blk validateAndNormalizeCommandAlloc(allocator, prompt, flavor) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    return try makeToolResponse(
                        allocator,
                        tool_name,
                        try std.fmt.allocPrint(
                            allocator,
                            "DEBUG_TOOL_ERROR\ntool={s}\nvalidation_error={s}\nmessage={s}",
                            .{ tool_name, @errorName(err), commandValidationMessage(err) },
                        ),
                    );
                },
            };
        }

        const extracted = try extractCommandFromPromptAlloc(allocator, flavor, prompt);
        if (extracted) |value| {
            break :blk value;
        }

        return try makeToolResponse(
            allocator,
            tool_name,
            try std.fmt.allocPrint(
                allocator,
                "DEBUG_TOOL_ERROR\ntool={s}\nmessage=no command-like input found in prompt",
                .{tool_name},
            ),
        );
    };
    defer allocator.free(command);

    const start_ms = std.time.milliTimestamp();

    const argv = switch (flavor) {
        .cmd => [_][]const u8{ "cmd", "/C", command },
        .bash => [_][]const u8{ "bash", "-lc", command },
    };

    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |err| {
        return try makeToolResponse(
            allocator,
            tool_name,
            try std.fmt.allocPrint(
                allocator,
                "DEBUG_TOOL_ERROR\ntool={s}\nspawn_error={s}",
                .{ tool_name, @errorName(err) },
            ),
        );
    };

    var stdout_capture = PipeCapture{};
    var stderr_capture = PipeCapture{};

    var stdout_thread: ?std.Thread = null;
    var stderr_thread: ?std.Thread = null;

    if (child.stdout) |stdout_file| {
        stdout_thread = try std.Thread.spawn(.{}, capturePipeMain, .{
            &stdout_capture,
            stdout_file,
            app_config.tool_exec_max_output_bytes,
        });
    } else {
        stdout_capture.done.store(true, .release);
    }
    if (child.stderr) |stderr_file| {
        stderr_thread = try std.Thread.spawn(.{}, capturePipeMain, .{
            &stderr_capture,
            stderr_file,
            app_config.tool_exec_max_output_bytes,
        });
    } else {
        stderr_capture.done.store(true, .release);
    }

    const timeout_deadline = start_ms + @as(i64, app_config.tool_exec_timeout_ms);
    var timed_out = false;
    while (true) {
        const stdout_done = stdout_capture.done.load(.acquire);
        const stderr_done = stderr_capture.done.load(.acquire);
        if (stdout_done and stderr_done) break;
        if (std.time.milliTimestamp() >= timeout_deadline) {
            timed_out = true;
            break;
        }
        std.Thread.sleep(2 * std.time.ns_per_ms);
    }

    const terminated_as: std.process.Child.Term = if (timed_out)
        child.kill() catch .{ .Unknown = 1 }
    else
        child.wait() catch .{ .Unknown = 1 };

    if (stdout_thread) |thread| thread.join();
    if (stderr_thread) |thread| thread.join();

    defer if (stdout_capture.bytes.len > 0) std.heap.page_allocator.free(stdout_capture.bytes);
    defer if (stderr_capture.bytes.len > 0) std.heap.page_allocator.free(stderr_capture.bytes);

    const end_ms = std.time.milliTimestamp();
    const duration_ms = if (end_ms >= start_ms)
        @as(u64, @intCast(end_ms - start_ms))
    else
        @as(u64, 0);

    const term_text = try childTermToTextAlloc(allocator, terminated_as);
    defer allocator.free(term_text);

    const status_tag = if (!timed_out and isSuccessfulTermination(terminated_as)) "DEBUG_TOOL_OK" else "DEBUG_TOOL_ERROR";
    const timeout_exceeded_text = if (timed_out) "true" else "false";
    const stdout_text = if (stdout_capture.err_name) |err_name|
        try std.fmt.allocPrint(allocator, "read_error={s}", .{err_name})
    else
        try allocator.dupe(u8, stdout_capture.bytes);
    defer allocator.free(stdout_text);

    const stderr_text = if (stderr_capture.err_name) |err_name|
        try std.fmt.allocPrint(allocator, "read_error={s}", .{err_name})
    else
        try allocator.dupe(u8, stderr_capture.bytes);
    defer allocator.free(stderr_text);

    const output = try std.fmt.allocPrint(
        allocator,
        "{s}\ntool={s}\nterm={s}\nduration_ms={d}\nmax_output_bytes={d}\ntimeout_policy_ms={d}\ntimeout_enforced=true\ntimeout_exceeded={s}\ncode={s}\ncommand={s}\n--- stdout ---\n{s}\n--- stderr ---\n{s}",
        .{
            status_tag,
            tool_name,
            term_text,
            duration_ms,
            app_config.tool_exec_max_output_bytes,
            app_config.tool_exec_timeout_ms,
            timeout_exceeded_text,
            if (timed_out) "command_timeout" else "command_completed",
            command,
            stdout_text,
            stderr_text,
        },
    );

    return try makeToolResponse(allocator, tool_name, output);
}

fn capturePipeMain(capture: *PipeCapture, file: std.fs.File, max_bytes: usize) void {
    defer capture.done.store(true, .release);
    capture.bytes = file.readToEndAlloc(std.heap.page_allocator, max_bytes) catch |err| {
        capture.err_name = @errorName(err);
        capture.bytes = &.{};
        return;
    };
}

pub fn extractCommandFromPromptAlloc(
    allocator: std.mem.Allocator,
    flavor: ShellFlavor,
    prompt: []const u8,
) !?[]u8 {
    const trimmed = std.mem.trim(u8, prompt, " \t\r\n\"'");
    if (trimmed.len == 0) return null;

    if (extractQuotedCommandSlice(trimmed)) |quoted| {
        const normalized = std.mem.trim(u8, quoted, " \t\r\n");
        if (normalized.len > 0) {
            return try validateAndNormalizeCommandAlloc(allocator, normalized, flavor);
        }
    }

    if (stripCommandInstructionPrefix(trimmed)) |candidate| {
        const normalized = normalizeExtractedCandidate(candidate);
        if (normalized.len > 0) {
            return try validateAndNormalizeCommandAlloc(allocator, normalized, flavor);
        }
    }

    if (extractInlineRunSegment(trimmed)) |candidate| {
        const normalized = normalizeExtractedCandidate(candidate);
        if (normalized.len > 0 and looksLikeCommandPrompt(normalized)) {
            return try validateAndNormalizeCommandAlloc(allocator, normalized, flavor);
        }
    }

    if (looksLikeCommandPrompt(trimmed)) {
        return try validateAndNormalizeCommandAlloc(allocator, trimmed, flavor);
    }

    return null;
}

fn validateAndNormalizeCommandAlloc(
    allocator: std.mem.Allocator,
    command: []const u8,
    flavor: ShellFlavor,
) ![]u8 {
    const trimmed = std.mem.trim(u8, command, " \t\r\n\"'");
    if (trimmed.len == 0) return error.EmptyCommand;
    if (trimmed.len > max_command_len) return error.CommandTooLong;
    if (containsUnsafeCommandByte(trimmed)) return error.UnsafeCharacter;

    const command_name = firstToken(trimmed) orelse return error.EmptyCommand;
    if (isDangerousCommandName(flavor, command_name)) return error.DangerousCommand;
    if (containsDangerousPattern(trimmed)) return error.DangerousPattern;

    return try allocator.dupe(u8, trimmed);
}

fn commandValidationMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.EmptyCommand => "command is empty",
        error.CommandTooLong => "command exceeds max length",
        error.UnsafeCharacter => "command contains unsafe shell control characters",
        error.DangerousCommand => "command is blocked by denylist",
        error.DangerousPattern => "command matches a blocked dangerous pattern",
        else => "command validation failed",
    };
}

fn looksLikeCommandPrompt(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n\"'");
    if (trimmed.len == 0) return false;

    if (std.mem.indexOfAny(u8, trimmed, "\r\n") != null) return false;

    const token = firstToken(trimmed) orelse return false;
    if (isLikelyNaturalLanguageLeadToken(token)) return false;

    if (std.mem.indexOfAny(u8, trimmed, "?!") != null) return false;
    return true;
}

fn containsUnsafeCommandByte(text: []const u8) bool {
    for (text) |byte| {
        if (byte < 0x20 or byte == 0x7f) return true;
        if (isUnsafeShellByte(byte)) return true;
    }
    return false;
}

fn isUnsafeShellByte(byte: u8) bool {
    return switch (byte) {
        '&', '|', ';', '>', '<', '`', '$' => true,
        else => false,
    };
}

fn firstToken(text: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    return it.next();
}

fn isDangerousCommandName(flavor: ShellFlavor, command_name: []const u8) bool {
    const cmd_deny = [_][]const u8{
        "format",
        "diskpart",
        "shutdown",
        "reboot",
        "bcdedit",
        "reg",
        "vssadmin",
        "wbadmin",
        "cipher",
        "takeown",
        "icacls",
    };
    const bash_deny = [_][]const u8{
        "shutdown",
        "reboot",
        "halt",
        "poweroff",
        "mkfs",
        "fdisk",
        "dd",
        "sudo",
    };

    const deny_set = switch (flavor) {
        .cmd => cmd_deny[0..],
        .bash => bash_deny[0..],
    };

    for (deny_set) |item| {
        if (std.ascii.eqlIgnoreCase(command_name, item)) return true;
    }
    return false;
}

fn containsDangerousPattern(command: []const u8) bool {
    return containsIgnoreCase(command, "curl ") and containsIgnoreCase(command, "| sh") or
        containsIgnoreCase(command, "wget ") and containsIgnoreCase(command, "| sh") or
        containsIgnoreCase(command, "rm -rf /") or
        containsIgnoreCase(command, "rm -rf /*") or
        containsIgnoreCase(command, "del /f /s /q c:\\") or
        containsIgnoreCase(command, "rmdir /s /q c:\\windows") or
        containsIgnoreCase(command, ":(){ :|:& };:");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return indexOfIgnoreCase(haystack, needle) != null;
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

fn trimTrailingPunctuation(token: []const u8) []const u8 {
    var end = token.len;
    while (end > 0) {
        switch (token[end - 1]) {
            '.', ',', '!', '?', ':', ';', '"', '\'' => end -= 1,
            else => break,
        }
    }
    return token[0..end];
}

fn normalizeExtractedCandidate(candidate: []const u8) []const u8 {
    var value = std.mem.trim(u8, candidate, " \t\r\n");
    value = trimTrailingPunctuation(value);

    if (value.len >= 4 and std.ascii.startsWithIgnoreCase(value, "the ")) {
        value = std.mem.trimLeft(u8, value[4..], " \t");
    }

    if (value.len >= 8 and std.ascii.endsWithIgnoreCase(value, " command")) {
        value = std.mem.trimRight(u8, value[0 .. value.len - 8], " \t");
    }

    return value;
}

fn stripCommandInstructionPrefix(text: []const u8) ?[]const u8 {
    const prefixes = [_][]const u8{
        "run the ",
        "execute the ",
        "run ",
        "execute ",
        "please run ",
        "please execute ",
        "can you run ",
        "can you execute ",
        "command: ",
        "cmd: ",
        "bash: ",
    };

    for (prefixes) |prefix| {
        if (std.ascii.startsWithIgnoreCase(text, prefix)) {
            return std.mem.trimLeft(u8, text[prefix.len..], " \t");
        }
    }

    return null;
}

fn extractInlineRunSegment(text: []const u8) ?[]const u8 {
    const markers = [_][]const u8{ " run ", " execute ", " command: " };

    for (markers) |marker| {
        if (indexOfIgnoreCase(text, marker)) |idx| {
            const segment = std.mem.trimLeft(u8, text[idx + marker.len ..], " \t");
            if (segment.len > 0) return segment;
        }
    }

    return null;
}

fn extractQuotedCommandSlice(text: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, text, '`')) |start| {
        const rest = text[start + 1 ..];
        if (std.mem.indexOfScalar(u8, rest, '`')) |end| {
            return rest[0..end];
        }
    }
    return null;
}

fn isLikelyNaturalLanguageLeadToken(token: []const u8) bool {
    const words = [_][]const u8{
        "what",
        "why",
        "how",
        "when",
        "where",
        "who",
        "please",
        "can",
        "could",
        "would",
        "should",
        "tell",
        "show",
        "explain",
        "get",
    };

    for (words) |word| {
        if (std.ascii.eqlIgnoreCase(token, word)) return true;
    }
    return false;
}

fn findWordIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) continue;

        const starts_word = (i == 0) or !isWordByte(haystack[i - 1]);
        const end_idx = i + needle.len;
        const ends_word = (end_idx == haystack.len) or !isWordByte(haystack[end_idx]);
        if (starts_word and ends_word) return i;
    }

    return null;
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
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

fn isSuccessfulTermination(term: std.process.Child.Term) bool {
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn childTermToTextAlloc(
    allocator: std.mem.Allocator,
    term: std.process.Child.Term,
) ![]u8 {
    return switch (term) {
        .Exited => |code| try std.fmt.allocPrint(allocator, "exited:{d}", .{code}),
        .Signal => |sig| try std.fmt.allocPrint(allocator, "signal:{d}", .{sig}),
        .Stopped => |sig| try std.fmt.allocPrint(allocator, "stopped:{d}", .{sig}),
        .Unknown => |code| try std.fmt.allocPrint(allocator, "unknown:{d}", .{code}),
    };
}

pub fn buildTestConfig(allocator: std.mem.Allocator, enable_exec: bool) !config.Config {
    return .{
        .listen_host = try allocator.dupe(u8, "127.0.0.1"),
        .listen_port = 8081,
        .debug_logging = false,
        .default_provider = try allocator.dupe(u8, "ollama_qwen"),
        .request_timeout_ms = 30_000,
        .provider_timeout_ms = 60_000,
        .instance_id = try allocator.dupe(u8, "local-instance"),
        .auth_api_key = try allocator.dupe(u8, ""),
        .ollama_base_url = try allocator.dupe(u8, "http://127.0.0.1:11434"),
        .ollama_model = try allocator.dupe(u8, "qwen:7b"),
        .ollama_think = false,
        .ollama_num_predict = 128,
        .ollama_temperature = 0.7,
        .ollama_repeat_penalty = 1.05,
        .openai_base_url = try allocator.dupe(u8, "https://api.openai.com/v1"),
        .openai_api_key = try allocator.dupe(u8, ""),
        .openai_model = try allocator.dupe(u8, "gpt-4.1-mini"),
        .openrouter_base_url = try allocator.dupe(u8, "https://openrouter.ai/api/v1"),
        .openrouter_api_key = try allocator.dupe(u8, ""),
        .openrouter_http_referer = try allocator.dupe(u8, ""),
        .openrouter_app_name = try allocator.dupe(u8, ""),
        .openrouter_model = try allocator.dupe(u8, "openrouter/auto"),
        .claude_base_url = try allocator.dupe(u8, "https://api.anthropic.com/v1"),
        .claude_api_key = try allocator.dupe(u8, ""),
        .claude_model = try allocator.dupe(u8, "claude-3-5-sonnet-latest"),
        .bedrock_runtime_base_url = try allocator.dupe(u8, ""),
        .bedrock_region = try allocator.dupe(u8, "us-east-1"),
        .bedrock_access_key_id = try allocator.dupe(u8, ""),
        .bedrock_secret_access_key = try allocator.dupe(u8, ""),
        .bedrock_session_token = try allocator.dupe(u8, ""),
        .bedrock_model = try allocator.dupe(u8, "amazon.nova-micro-v1:0"),
        .llama_cpp_base_url = try allocator.dupe(u8, "http://127.0.0.1:8080"),
        .llama_cpp_api_key = try allocator.dupe(u8, ""),
        .llama_cpp_model = try allocator.dupe(u8, "local-model"),
        .session_store_path = try allocator.dupe(u8, "logs/sessions"),
        .session_retention_messages = 24,
        .tool_exec_enabled = enable_exec,
        .tool_exec_timeout_ms = 15_000,
        .tool_exec_max_output_bytes = 65_536,
        .loop_stream_progress_enabled = true,
        .max_concurrent_connections = 64,
    };
}

test "execute cmd tool returns disabled marker when not enabled" {
    if (@import("builtin").os.tag != .windows) return;

    const allocator = std.testing.allocator;
    var cfg = try buildTestConfig(allocator, false);
    defer cfg.deinit(allocator);

    const messages = try allocator.alloc(types.Message, 1);
    messages[0] = .{
        .role = try allocator.dupe(u8, "user"),
        .content = try allocator.dupe(u8, "echo hello"),
    };

    const req = types.Request{
        .prompt = try allocator.dupe(u8, "echo hello"),
        .messages = messages,
        .provider = null,
        .model = null,
        .session_id = null,
        .tenant_id = null,
        .max_context_tokens = null,
        .tools = try allocator.alloc(types.Tool, 0),
        .tool_choice = null,
    };
    defer req.deinit(allocator);

    var result = try execute(allocator, &cfg, req, .cmd);
    defer result.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "DEBUG_TOOL_ERROR") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "disabled") != null);
}

test "extractCommandFromPromptAlloc extracts from run prefix" {
    const allocator = std.testing.allocator;

    const maybe_cmd = try extractCommandFromPromptAlloc(
        allocator,
        .cmd,
        "Please run zig build test",
    );
    defer if (maybe_cmd) |cmd| allocator.free(cmd);

    try std.testing.expect(maybe_cmd != null);
    try std.testing.expectEqualStrings("zig build test", maybe_cmd.?);
}

test "execute cmd tool rejects unsafe chaining" {
    if (@import("builtin").os.tag != .windows) return;

    const allocator = std.testing.allocator;
    var cfg = try buildTestConfig(allocator, true);
    defer cfg.deinit(allocator);

    const messages = try allocator.alloc(types.Message, 1);
    messages[0] = .{
        .role = try allocator.dupe(u8, "user"),
        .content = try allocator.dupe(u8, "ping 127.0.0.1 && ipconfig"),
    };

    const req = types.Request{
        .prompt = try allocator.dupe(u8, "ping 127.0.0.1 && ipconfig"),
        .messages = messages,
        .provider = null,
        .model = null,
        .session_id = null,
        .tenant_id = null,
        .max_context_tokens = null,
        .tools = try allocator.alloc(types.Tool, 0),
        .tool_choice = null,
    };
    defer req.deinit(allocator);

    var result = try execute(allocator, &cfg, req, .cmd);
    defer result.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "DEBUG_TOOL_ERROR") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "unsafe") != null);
}

test "execute cmd tool blocks dangerous denylist command" {
    if (@import("builtin").os.tag != .windows) return;

    const allocator = std.testing.allocator;
    var cfg = try buildTestConfig(allocator, true);
    defer cfg.deinit(allocator);

    const messages = try allocator.alloc(types.Message, 1);
    messages[0] = .{
        .role = try allocator.dupe(u8, "user"),
        .content = try allocator.dupe(u8, "shutdown /s /t 0"),
    };

    const req = types.Request{
        .prompt = try allocator.dupe(u8, "shutdown /s /t 0"),
        .messages = messages,
        .provider = null,
        .model = null,
        .session_id = null,
        .tenant_id = null,
        .max_context_tokens = null,
        .tools = try allocator.alloc(types.Tool, 0),
        .tool_choice = null,
    };
    defer req.deinit(allocator);

    var result = try execute(allocator, &cfg, req, .cmd);
    defer result.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "DEBUG_TOOL_ERROR") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "denylist") != null);
}

test "execute cmd tool enforces timeout and kills process" {
    if (@import("builtin").os.tag != .windows) return;

    const allocator = std.testing.allocator;
    var cfg = try buildTestConfig(allocator, true);
    defer cfg.deinit(allocator);
    cfg.tool_exec_timeout_ms = 200;

    const messages = try allocator.alloc(types.Message, 1);
    messages[0] = .{
        .role = try allocator.dupe(u8, "user"),
        .content = try allocator.dupe(u8, "powershell -NoProfile -Command Start-Sleep -Seconds 3"),
    };

    const req = types.Request{
        .prompt = try allocator.dupe(u8, "powershell -NoProfile -Command Start-Sleep -Seconds 3"),
        .messages = messages,
        .provider = null,
        .model = null,
        .session_id = null,
        .tenant_id = null,
        .max_context_tokens = null,
        .tools = try allocator.alloc(types.Tool, 0),
        .tool_choice = null,
    };
    defer req.deinit(allocator);

    var result = try execute(allocator, &cfg, req, .cmd);
    defer result.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "DEBUG_TOOL_ERROR") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "timeout_enforced=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "timeout_exceeded=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "code=command_timeout") != null);
}

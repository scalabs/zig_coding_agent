//! ReAct (Reasoning + Acting) loop support.
//!
//! Implements the Thought → Action → Observation paradigm from Yao et al., 2022.
//! The model produces structured Thought/Action pairs, the harness executes the
//! action and injects the result as an Observation, and the cycle repeats until
//! the model emits Finish[answer] or the turn budget is exhausted.
const std = @import("std");
const config = @import("config.zig");
const types = @import("types.zig");
const command_exec_tool = @import("tools/command_exec.zig");

/// System prompt injected at the start of every ReAct loop to instruct the
/// model on the required Thought/Action/Observation format.
pub const system_prompt =
    "You are running in ReAct (Reasoning + Acting) mode.\n" ++
    "You MUST follow this format strictly for every step:\n\n" ++
    "Thought N: <your reasoning about what to do next>\n" ++
    "Action N: <one of the available actions>\n\n" ++
    "After each Action the system will inject:\n" ++
    "Observation N: <result of the action>\n\n" ++
    "Available actions:\n" ++
    "  Search[query]   - search for information\n" ++
    "  Lookup[term]    - look up a term in the current context\n" ++
    "  Cmd[command]    - execute a shell command (may require confirmation)\n" ++
    "  Finish[answer]  - return the final answer and end the loop\n\n" ++
    "Rules:\n" ++
    "- Always start with a Thought, then an Action.\n" ++
    "- Never produce an Observation yourself; the system provides them.\n" ++
    "- Use Finish[answer] when you have the final answer.\n" ++
    "- Be concrete: use specific names, values, steps, and short outputs instead of vague summaries.\n" ++
    "- If you need information, ask for the exact term or command that will resolve it.\n" ++
    "- If an action fails, adjust your approach in the next Thought.\n";

pub fn buildSystemPromptAlloc(allocator: std.mem.Allocator, tools: []const types.Tool) ![]u8 {
    if (tools.len == 0) return try allocator.dupe(u8, system_prompt);

    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, system_prompt);
    try out.appendSlice(
        allocator,
        "\nRequested API tools (names only; invoke with exact name in brackets):\n",
    );

    for (tools, 0..) |tool, idx| {
        if (idx > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, " ");
        try out.appendSlice(allocator, tool.name);
    }

    try out.appendSlice(
        allocator,
        "\n\nTool rules:\n" ++
            "- For file_write, include the path and fenced code block inside the brackets, for example:\n" ++
            "  Action N: file_write[write relative/path\n```lang\n...\n```]\n" ++
            "- Put the full tool input inside the brackets.\n",
    );

    return try out.toOwnedSlice(allocator);
}

/// Parsed action extracted from a model response.
pub const ToolAction = struct {
    name: []const u8,
    argument: []const u8,
};

pub const ReactAction = union(enum) {
    search: []const u8,
    lookup: []const u8,
    cmd: []const u8,
    finish: []const u8,
    tool: ToolAction,
    unknown: []const u8,
};

/// Scans model output for the last `Action [N]: Type[arg]` line and returns
/// the parsed action variant.
///
/// Parsing rules:
/// - Case-insensitive match on the `Action` keyword.
/// - The turn number after `Action` is optional (the harness tracks turns).
/// - Brackets are mandatory for the argument.
/// - Greedy bracket matching: takes everything up to the last `]` after the
///   action, allowing multi-line tool inputs such as fenced code blocks.
/// - Returns `null` when no action line is found.
pub fn parseReactAction(output: []const u8) ?ReactAction {
    // Scan for the FIRST Action directive that lives outside a
    // <think>...</think> block. Returning the first action (rather than the
    // last) lets the loop drive multi-step plans one observation at a time:
    // if the model speculatively emits Action 2 before seeing Observation 1,
    // we execute Action 1 and let Observation 1 inform Action 2 on the next
    // turn.
    var first_action_start: ?usize = null;
    var inside_think = false;
    var cursor: usize = 0;
    while (cursor < output.len) {
        if (!inside_think and startsWithIgnoreCase(output[cursor..], "<think>")) {
            inside_think = true;
            cursor += "<think>".len;
            continue;
        }
        if (inside_think and startsWithIgnoreCase(output[cursor..], "</think>")) {
            inside_think = false;
            cursor += "</think>".len;
            continue;
        }

        if (inside_think) {
            cursor += 1;
            continue;
        }

        const line_start = cursor;
        var line_end = cursor;
        while (line_end < output.len and output[line_end] != '\n' and output[line_end] != '\r') {
            line_end += 1;
        }

        const raw_line = output[line_start..line_end];
        const line = std.mem.trimLeft(u8, raw_line, " \t");
        if (startsWithActionDirective(line)) {
            first_action_start = line_start + (raw_line.len - line.len);
            break;
        }

        cursor = line_end;
        while (cursor < output.len and (output[cursor] == '\n' or output[cursor] == '\r')) {
            cursor += 1;
        }
    }

    const action_start = first_action_start orelse return null;
    // For multi-line bracket arguments (fenced code blocks) we need to
    // bound the search for the closing `]` to the FIRST action only, not
    // any later actions the model may have over-eagerly emitted. We do this
    // by clipping the search window at the next `Action ` directive line.
    const action_text = clipAtNextActionDirective(output[action_start..]);

    // Extract the part after "Action" (and optional number + colon).
    const after_keyword = action_text[6..]; // "Action" is 6 chars
    const after_prefix = skipActionPrefix(after_keyword);
    const trimmed = std.mem.trimLeft(u8, after_prefix, " \t");

    if (trimmed.len == 0) return null;

    // Find the bracket pair: Type[arg]
    const open_bracket = std.mem.indexOfScalar(u8, trimmed, '[') orelse return null;
    // Greedy: find the last ']' after the action.
    const close_bracket = std.mem.lastIndexOfScalar(u8, trimmed, ']') orelse return null;
    if (close_bracket <= open_bracket) return null;

    const action_type = std.mem.trim(u8, trimmed[0..open_bracket], " \t");
    const argument = trimmed[open_bracket + 1 .. close_bracket];

    if (action_type.len == 0) return null;

    if (eqlIgnoreCase(action_type, "search")) return .{ .search = argument };
    if (eqlIgnoreCase(action_type, "lookup")) return .{ .lookup = argument };
    if (eqlIgnoreCase(action_type, "cmd")) return .{ .cmd = argument };
    if (eqlIgnoreCase(action_type, "finish")) return .{ .finish = argument };
    if (isKnownApiToolAction(action_type)) {
        return .{ .tool = .{ .name = action_type, .argument = argument } };
    }

    return .{ .unknown = trimmed[0 .. close_bracket + 1] };
}

/// Executes a parsed ReAct action and returns the observation text.
///
/// - `Search` and `Lookup` return stubs (to be wired to tools/APIs later).
/// - `Cmd` delegates to the existing command_exec tool infrastructure.
/// - `Finish` should be handled by the caller before reaching this function,
///   but returns the answer content as a fallback.
/// - `Tool` is only executable by API loop callers that have a request tool
///   list; the standalone executor returns a hint.
/// - `Unknown` returns an error hint listing available actions.
pub fn executeReactAction(
    allocator: std.mem.Allocator,
    action: ReactAction,
    app_config: *const config.Config,
) ![]u8 {
    return switch (action) {
        .search => |query| try std.fmt.allocPrint(
            allocator,
            "Search is not yet implemented. Query was: {s}",
            .{query},
        ),
        .lookup => |term| try std.fmt.allocPrint(
            allocator,
            "Lookup is not yet implemented. Term was: {s}",
            .{term},
        ),
        .cmd => |command| try executeReactCmd(allocator, command, app_config),
        .finish => |answer| try allocator.dupe(u8, answer),
        .tool => |tool| try std.fmt.allocPrint(
            allocator,
            "Tool action {s} is only available in API loop mode when requested by the client.",
            .{tool.name},
        ),
        .unknown => |text| try std.fmt.allocPrint(
            allocator,
            "Unknown action: {s}. Available actions: Search, Lookup, Cmd, Finish.",
            .{text},
        ),
    };
}

/// Formats an observation message with turn numbering.
pub fn formatObservation(
    allocator: std.mem.Allocator,
    turn: usize,
    observation_text: []const u8,
) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "Observation {d}: {s}",
        .{ turn, observation_text },
    );
}

// ── internal helpers ──────────────────────────────────────────────────

fn executeReactCmd(
    allocator: std.mem.Allocator,
    command: []const u8,
    app_config: *const config.Config,
) ![]u8 {
    if (!app_config.tool_exec_enabled) {
        return try allocator.dupe(
            u8,
            "Command execution is disabled. Set LLM_ROUTER_TOOL_EXEC_ENABLED=1 to enable.",
        );
    }

    // Build a synthetic single-prompt request for the command tool.
    const messages = try allocator.alloc(types.Message, 1);
    errdefer allocator.free(messages);

    const role = try allocator.dupe(u8, "user");
    errdefer allocator.free(role);

    const content = try allocator.dupe(u8, command);
    errdefer allocator.free(content);

    messages[0] = .{ .role = role, .content = content };

    const req = types.Request{
        .prompt = try allocator.dupe(u8, command),
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

    const shell: command_exec_tool.ShellFlavor = if (@import("builtin").os.tag == .windows) .cmd else .bash;
    var result = try command_exec_tool.execute(allocator, app_config, req, shell, "react-local");
    defer result.deinit(allocator);

    // Dupe the output to transfer ownership to the caller; result.deinit
    // will free the original.
    return try allocator.dupe(u8, result.output);
}

/// Returns true if the line starts with the exact `Action` keyword.
fn startsWithActionDirective(line: []const u8) bool {
    if (line.len < 6) return false;
    if (!eqlIgnoreCase(line[0..6], "action")) return false;

    if (line.len == 6) return true;
    return switch (line[6]) {
        ' ', '\t', ':', '0'...'9' => true,
        else => false,
    };
}

/// Skips past optional whitespace, turn number, and colon after `Action`.
fn skipActionPrefix(input: []const u8) []const u8 {
    var i: usize = 0;

    // Skip leading whitespace.
    while (i < input.len and (input[i] == ' ' or input[i] == '\t')) : (i += 1) {}

    // Skip optional digits (turn number).
    while (i < input.len and std.ascii.isDigit(input[i])) : (i += 1) {}

    while (i < input.len and (input[i] == ' ' or input[i] == '\t')) : (i += 1) {}

    // Skip optional colon.
    if (i < input.len and input[i] == ':') {
        i += 1;
    }

    while (i < input.len and (input[i] == ' ' or input[i] == '\t')) : (i += 1) {}

    return input[i..];
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (prefix.len > value.len) return false;
    return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

/// Returns a prefix of `text` that ends just before the next line starting
/// with `Action ` (case-insensitive). The first line is always kept since it
/// is itself the Action directive being parsed.
fn clipAtNextActionDirective(text: []const u8) []const u8 {
    var cursor: usize = 0;
    // Skip the directive's own first line.
    while (cursor < text.len and text[cursor] != '\n' and text[cursor] != '\r') {
        cursor += 1;
    }

    while (cursor < text.len) {
        while (cursor < text.len and (text[cursor] == '\n' or text[cursor] == '\r')) {
            cursor += 1;
        }
        const line_start = cursor;
        while (cursor < text.len and text[cursor] != '\n' and text[cursor] != '\r') {
            cursor += 1;
        }

        const raw_line = text[line_start..cursor];
        const line = std.mem.trimLeft(u8, raw_line, " \t");
        if (startsWithActionDirective(line)) {
            return text[0..line_start];
        }
    }
    return text;
}

fn isKnownApiToolAction(action_type: []const u8) bool {
    return eqlIgnoreCase(action_type, "echo") or
        eqlIgnoreCase(action_type, "utc") or
        eqlIgnoreCase(action_type, "bash") or
        eqlIgnoreCase(action_type, "file_read") or
        eqlIgnoreCase(action_type, "file_write") or
        eqlIgnoreCase(action_type, "file_search");
}

// ── tests ─────────────────────────────────────────────────────────────

test "parseReactAction extracts Search action" {
    const action = parseReactAction("Thought 1: I need to find info\nAction 1: Search[Colorado orogeny]");
    try std.testing.expect(action != null);
    switch (action.?) {
        .search => |query| try std.testing.expectEqualStrings("Colorado orogeny", query),
        else => return error.UnexpectedActionType,
    }
}

test "parseReactAction extracts Finish action" {
    const action = parseReactAction("Action 3: Finish[the answer is 42]");
    try std.testing.expect(action != null);
    switch (action.?) {
        .finish => |answer| try std.testing.expectEqualStrings("the answer is 42", answer),
        else => return error.UnexpectedActionType,
    }
}

test "parseReactAction extracts Cmd action" {
    const action = parseReactAction("Action 2: Cmd[zig build test]");
    try std.testing.expect(action != null);
    switch (action.?) {
        .cmd => |command| try std.testing.expectEqualStrings("zig build test", command),
        else => return error.UnexpectedActionType,
    }
}

test "parseReactAction extracts Lookup action" {
    const action = parseReactAction("Action 1: Lookup[eastern sector]");
    try std.testing.expect(action != null);
    switch (action.?) {
        .lookup => |term| try std.testing.expectEqualStrings("eastern sector", term),
        else => return error.UnexpectedActionType,
    }
}

test "parseReactAction returns null for no action" {
    const action = parseReactAction("Some text with no action line at all");
    try std.testing.expect(action == null);
}

test "parseReactAction returns unknown for unrecognized action type" {
    const action = parseReactAction("Action 1: UnknownAction[foo]");
    try std.testing.expect(action != null);
    switch (action.?) {
        .unknown => {},
        else => return error.UnexpectedActionType,
    }
}

test "parseReactAction extracts requested API tool action" {
    const action = parseReactAction("Thought 1: write the file\nAction 1: file_write[write app.cpp\n```cpp\nint main() { return 0; }\n```]");
    try std.testing.expect(action != null);
    switch (action.?) {
        .tool => |tool| {
            try std.testing.expectEqualStrings("file_write", tool.name);
            try std.testing.expect(std.mem.indexOf(u8, tool.argument, "app.cpp") != null);
            try std.testing.expect(std.mem.indexOf(u8, tool.argument, "int main()") != null);
        },
        else => return error.UnexpectedActionType,
    }
}

test "buildSystemPromptAlloc includes requested tools" {
    const allocator = std.testing.allocator;
    const tools = [_]types.Tool{
        .{ .name = "file_write", .description = "write files" },
    };

    const prompt = try buildSystemPromptAlloc(allocator, tools[0..]);
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "file_write") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "names only") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "file_write[write relative/path") != null);
}

test "parseReactAction handles nested brackets greedily" {
    const action = parseReactAction("Action 5: Finish[1,800 to 7,000 ft]");
    try std.testing.expect(action != null);
    switch (action.?) {
        .finish => |answer| try std.testing.expectEqualStrings("1,800 to 7,000 ft", answer),
        else => return error.UnexpectedActionType,
    }
}

test "parseReactAction is case-insensitive" {
    const action = parseReactAction("action 1: search[test query]");
    try std.testing.expect(action != null);
    switch (action.?) {
        .search => |query| try std.testing.expectEqualStrings("test query", query),
        else => return error.UnexpectedActionType,
    }
}

test "parseReactAction rejects actionable text" {
    const action = parseReactAction("Actionable note: Search[bad]");
    try std.testing.expect(action == null);
}

test "parseReactAction tolerates missing turn number" {
    const action = parseReactAction("Action: Search[no number]");
    try std.testing.expect(action != null);
    switch (action.?) {
        .search => |query| try std.testing.expectEqualStrings("no number", query),
        else => return error.UnexpectedActionType,
    }
}

test "parseReactAction returns first action when model emits multiple" {
    const output =
        "Thought 1: first thought\n" ++
        "Action 1: Search[first]\n" ++
        "Thought 2: second thought\n" ++
        "Action 2: Finish[final answer]";
    const action = parseReactAction(output);
    try std.testing.expect(action != null);
    switch (action.?) {
        .search => |query| try std.testing.expectEqualStrings("first", query),
        else => return error.UnexpectedActionType,
    }
}

test "parseReactAction ignores Action mentions inside <think> block" {
    const output =
        "<think>I should probably emit Action 1: Search[bad]\nsomething</think>\n" ++
        "Action 1: Finish[real answer]";
    const action = parseReactAction(output);
    try std.testing.expect(action != null);
    switch (action.?) {
        .finish => |answer| try std.testing.expectEqualStrings("real answer", answer),
        else => return error.UnexpectedActionType,
    }
}

test "parseReactAction parses multi-line first action when a second follows" {
    const output =
        "Thought 1: write the file\n" ++
        "Action 1: file_write[calculator.cpp\n```cpp\nint main(){}\n```]\n" ++
        "Action 2: cmd[g++ -o calculator calculator.cpp]";
    const action = parseReactAction(output);
    try std.testing.expect(action != null);
    switch (action.?) {
        .tool => |tool| {
            try std.testing.expectEqualStrings("file_write", tool.name);
            try std.testing.expect(std.mem.indexOf(u8, tool.argument, "calculator.cpp") != null);
            try std.testing.expect(std.mem.indexOf(u8, tool.argument, "int main(){}") != null);
            try std.testing.expect(std.mem.indexOf(u8, tool.argument, "g++") == null);
        },
        else => return error.UnexpectedActionType,
    }
}

test "formatObservation produces correct format" {
    const allocator = std.testing.allocator;
    const result = try formatObservation(allocator, 3, "The answer is here");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Observation 3: The answer is here", result);
}

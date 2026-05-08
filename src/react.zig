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
    "  Cmd[command]    - execute a shell command (only if tools are enabled)\n" ++
    "  Finish[answer]  - return the final answer and end the loop\n\n" ++
    "Rules:\n" ++
    "- Always start with a Thought, then an Action.\n" ++
    "- Never produce an Observation yourself; the system provides them.\n" ++
    "- Use Finish[answer] when you have the final answer.\n" ++
    "- Be concrete: use specific names, values, steps, and short outputs instead of vague summaries.\n" ++
    "- If you need information, ask for the exact term or command that will resolve it.\n" ++
    "- If an action fails, adjust your approach in the next Thought.\n";

/// Parsed action extracted from a model response.
pub const ReactAction = union(enum) {
    search: []const u8,
    lookup: []const u8,
    cmd: []const u8,
    finish: []const u8,
    unknown: []const u8,
};

/// Scans model output for the last `Action [N]: Type[arg]` line and returns
/// the parsed action variant.
///
/// Parsing rules:
/// - Case-insensitive match on the `Action` keyword.
/// - The turn number after `Action` is optional (the harness tracks turns).
/// - Brackets are mandatory for the argument.
/// - Greedy bracket matching: takes everything up to the last `]` on the line.
/// - Returns `null` when no action line is found.
pub fn parseReactAction(output: []const u8) ?ReactAction {
    // Scan backwards through lines to find the last Action directive.
    var last_action_line: ?[]const u8 = null;
    var lines = std.mem.splitAny(u8, output, "\n\r");
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t");
        if (line.len == 0) continue;
        if (startsWithActionDirective(line)) {
            last_action_line = line;
        }
    }

    const action_line = last_action_line orelse return null;

    // Extract the part after "Action" (and optional number + colon).
    const after_keyword = action_line[6..]; // "Action" is 6 chars
    const after_prefix = skipActionPrefix(after_keyword);
    const trimmed = std.mem.trim(u8, after_prefix, " \t");

    if (trimmed.len == 0) return null;

    // Find the bracket pair: Type[arg]
    const open_bracket = std.mem.indexOfScalar(u8, trimmed, '[') orelse return null;
    // Greedy: find the last ']' on the line.
    const close_bracket = std.mem.lastIndexOfScalar(u8, trimmed, ']') orelse return null;
    if (close_bracket <= open_bracket) return null;

    const action_type = std.mem.trim(u8, trimmed[0..open_bracket], " \t");
    const argument = trimmed[open_bracket + 1 .. close_bracket];

    if (action_type.len == 0) return null;

    if (eqlIgnoreCase(action_type, "search")) return .{ .search = argument };
    if (eqlIgnoreCase(action_type, "lookup")) return .{ .lookup = argument };
    if (eqlIgnoreCase(action_type, "cmd")) return .{ .cmd = argument };
    if (eqlIgnoreCase(action_type, "finish")) return .{ .finish = argument };

    return .{ .unknown = trimmed };
}

/// Executes a parsed ReAct action and returns the observation text.
///
/// - `Search` and `Lookup` return stubs (to be wired to tools/APIs later).
/// - `Cmd` delegates to the existing command_exec tool infrastructure.
/// - `Finish` should be handled by the caller before reaching this function,
///   but returns the answer content as a fallback.
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
    var result = try command_exec_tool.execute(allocator, app_config, req, shell);
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

test "parseReactAction uses last action line when multiple exist" {
    const output =
        "Thought 1: first thought\n" ++
        "Action 1: Search[first]\n" ++
        "Thought 2: second thought\n" ++
        "Action 2: Finish[final answer]";
    const action = parseReactAction(output);
    try std.testing.expect(action != null);
    switch (action.?) {
        .finish => |answer| try std.testing.expectEqualStrings("final answer", answer),
        else => return error.UnexpectedActionType,
    }
}

test "formatObservation produces correct format" {
    const allocator = std.testing.allocator;
    const result = try formatObservation(allocator, 3, "The answer is here");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Observation 3: The answer is here", result);
}

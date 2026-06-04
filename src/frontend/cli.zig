const std = @import("std");
const types = @import("types.zig");
const client = @import("client.zig");
const ui = @import("ui.zig");

pub fn runCli() !void {
    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();

    try ui.printHeader(stdout);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try stdout.writeAll("\nChecking backend health...\n");
    const health = client.checkBackendHealth(allocator) catch |err| {
        try ui.printWarn(stdout, "Backend is not reachable. Start it with: zig build run");
        std.debug.print("Connection error: {s}\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(health);

    try ui.printBackendHealth(stdout, health);

    try stdout.writeAll("\nChecking provider diagnostics...\n");
    const diagnostics = client.getProviderDiagnostics(allocator) catch |err| {
        try ui.printWarn(stdout, "Could not fetch provider diagnostics.");
        std.debug.print("Diagnostics error: {s}\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(diagnostics);

    try ui.printProviderDiagnostics(stdout, diagnostics);

    const provider = try chooseProvider(stdin, stdout);
    const mode = try chooseMode(stdin, stdout);

    var session_buffer: [128]u8 = undefined;
    try stdout.writeAll("\nSession label (optional, press Enter to skip): ");
    const session_raw = try readLine(stdin, &session_buffer);
    const session_label = std.mem.trim(u8, session_raw, " \t\r\n");
    
    while (true) {
    var prompt_buffer: [2048]u8 = undefined;
    try stdout.writeAll("\nEnter prompt, or type 'exit' to quit: ");
    const prompt_raw = try readLine(stdin, &prompt_buffer);
    const prompt = std.mem.trim(u8, prompt_raw, " \t\r\n");

    if (prompt.len == 0) {
        try ui.printWarn(stdout, "No prompt entered.");
        continue;
    }

    if (std.mem.eql(u8, prompt, "exit")) {
        try stdout.writeAll("\nExiting frontend session.\n");
        return;
    }

    try client.runBackend(
        allocator,
        prompt,
        provider,
        mode,
        session_label,
    );
}
    
}

fn chooseProvider(stdin: std.fs.File, stdout: std.fs.File) !types.Provider {
    try stdout.writeAll(
        \\Choose provider:
        \\1. Ollama
        \\2. OpenAI
        \\3. OpenRouter
        \\4. Claude
        \\5. Bedrock
        \\6. llama.cpp
        \\Selection: 
    );

    var buffer: [32]u8 = undefined;
    const choice = std.mem.trim(u8, try readLine(stdin, &buffer), " \t\r\n");

    if (std.mem.eql(u8, choice, "2")) return .openai;
    if (std.mem.eql(u8, choice, "3")) return .openrouter;
    if (std.mem.eql(u8, choice, "4")) return .claude;
    if (std.mem.eql(u8, choice, "5")) return .bedrock;
    if (std.mem.eql(u8, choice, "6")) return .llama_cpp;    return .ollama;
}

fn chooseMode(stdin: std.fs.File, stdout: std.fs.File) !types.LoopMode {
    while (true) {
        try stdout.writeAll(
            \\
            \\Choose loop mode:
            \\  1. Basic        prompt-response loop
            \\  2. Agent        multi-turn agent loop
            \\  3. ReAct        Thought -> Action -> Observation
            \\Selection: 
        );

        var buffer: [32]u8 = undefined;
        const choice = std.mem.trim(u8, try readLine(stdin, &buffer), " \t\r\n");

        if (std.mem.eql(u8, choice, "1")) return .basic;
        if (std.mem.eql(u8, choice, "2")) return .agent;
        if (std.mem.eql(u8, choice, "3")) return .react;

        try ui.printWarn(stdout, "Invalid mode selection. Please choose 1, 2, or 3.");
    }
}
fn readLine(file: std.fs.File, buffer: []u8) ![]u8 {
    var index: usize = 0;

    while (index < buffer.len) {
        var byte: [1]u8 = undefined;
        const n = try file.read(&byte);

        if (n == 0) break;
        if (byte[0] == '\n') break;

        buffer[index] = byte[0];
        index += 1;
    }

    return buffer[0..index];
}

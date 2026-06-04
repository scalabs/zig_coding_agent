const std = @import("std");

pub fn printHeader(stdout: std.fs.File) !void {
    try stdout.writeAll("\nLightweight AI Agent Harness\n");
    try stdout.writeAll("Modular Frontend Interface\n");
    try stdout.writeAll("--------------------------------------\n");
}

pub fn printWarn(stdout: std.fs.File, msg: []const u8) !void {
    try stdout.writeAll("Warning: ");
    try stdout.writeAll(msg);
    try stdout.writeAll("\n");
}

pub fn printSection(stdout: std.fs.File, title: []const u8) !void {
    try stdout.writeAll("\n");
    try stdout.writeAll(title);
    try stdout.writeAll("\n");
    try stdout.writeAll("--------------------------------------\n");
}

pub fn printBackendHealth(stdout: std.fs.File, health_json: []const u8) !void {
    try printSection(stdout, "Backend Health");

    if (std.mem.indexOf(u8, health_json, "\"status\":\"ok\"") != null) {
        try stdout.writeAll("Backend: online\n");
    } else {
        try stdout.writeAll("Backend: unknown\n");
    }

    if (extractJsonStringValue(health_json, "instance_id")) |instance| {
        try stdout.writeAll("Instance: ");
        try stdout.writeAll(instance);
        try stdout.writeAll("\n");
    }
}

pub fn printProviderDiagnostics(stdout: std.fs.File, diagnostics_json: []const u8) !void {
    try printSection(stdout, "Provider Diagnostics");

    if (extractJsonStringValue(diagnostics_json, "default_provider")) |provider| {
        try stdout.writeAll("Default provider: ");
        try stdout.writeAll(provider);
        try stdout.writeAll("\n");
    }

    if (std.mem.indexOf(u8, diagnostics_json, "\"ollama\"") != null) {
        if (std.mem.indexOf(u8, diagnostics_json, "\"reachable\":true") != null) {
            try stdout.writeAll("Ollama: reachable\n");
        } else {
            try stdout.writeAll("Ollama: not reachable\n");
        }
    }

    if (std.mem.indexOf(u8, diagnostics_json, "\"openrouter\"") != null) {
        if (std.mem.indexOf(u8, diagnostics_json, "\"configured_api_key\":true") != null) {
            try stdout.writeAll("OpenRouter: API key configured\n");
        } else {
            try stdout.writeAll("OpenRouter: API key missing\n");
        }
    }

    if (std.mem.indexOf(u8, diagnostics_json, "\"bedrock\"") != null) {
        if (std.mem.indexOf(u8, diagnostics_json, "\"configured_credentials\":true") != null) {
            try stdout.writeAll("Bedrock: credentials configured\n");
        } else {
            try stdout.writeAll("Bedrock: credentials missing\n");
        }
    }
}

pub fn printJsonBlock(stdout: std.fs.File, title: []const u8, json: []const u8) !void {
    try printSection(stdout, title);
    try stdout.writeAll(json);
    try stdout.writeAll("\n");
}

fn extractJsonStringValue(json: []const u8, key: []const u8) ?[]const u8 {
    var pattern_buf: [128]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\":\"", .{key}) catch return null;

    const start = std.mem.indexOf(u8, json, pattern) orelse return null;
    const value_start = start + pattern.len;
    const rest = json[value_start..];
    const value_end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;

    return rest[0..value_end];
}

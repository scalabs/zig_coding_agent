const frontend = @import("frontend/cli.zig");

pub fn main() !void {
    try frontend.runCli();
}

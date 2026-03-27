const runner = @import("../runner.zig");

pub fn main() !void {
    try runner.runTool("vm-start-linux");
}

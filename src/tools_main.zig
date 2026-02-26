const dispatch = @import("tools/dispatch.zig");

pub fn main() !void {
    try dispatch.main();
}

test "tools dispatch self-test" {
    _ = dispatch;
}

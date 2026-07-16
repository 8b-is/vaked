// GENESIS_SEAL: 7c242080
const std = @import("std");

test {
    _ = @import("lexer_test.zig");
    _ = @import("parser_test.zig");
    _ = @import("resolve_test.zig");
}

pub fn main() !void {
    std.debug.print("vakedz VX.XX.XX\n", .{});
}

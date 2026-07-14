// GENESIS_SEAL: 7c242080
const std = @import("std");
const lib = @import("lib");
const lexer = @import("lexer.zig");

test {
    _ = @import("lexer_test.zig");
}

pub fn main() !void {
    std.debug.print("vakedz VX.XX.XX\n", .{});
}

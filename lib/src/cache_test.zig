// GENESIS_SEAL: 7c242080
const std = @import("std");
const testing = std.testing;
const cache = @import("cache.zig");

test "sha256Hex empty string" {
    var out: [64]u8 = undefined;
    cache.sha256Hex("", &out);
    try testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &out,
    );
}

test "Phase enum" {
    try testing.expectEqualStrings("parse", cache.Phase.parse.str());
    try testing.expectEqualStrings("check", cache.Phase.check.str());
    try testing.expectEqualStrings("lower", cache.Phase.lower.str());
}

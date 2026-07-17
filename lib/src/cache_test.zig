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

test "chainHex from GENESIS" {
    var out: [64]u8 = undefined;
    cache.chainHex(cache.GENESIS, "payload", &out);
    try testing.expectEqualStrings(
        "574feb55908dbb2b4c72bc2dc3e70fc1b8f1b32264e064b5a557c6e6a068b3a8",
        &out,
    );
}

test "Cache stub open/lookup/put/verify" {
    var c = try cache.Cache.open(testing.allocator, "/tmp/vakedz-test-root");
    defer c.deinit();
    try testing.expectEqualStrings("/tmp/vakedz-test-root/.vakedz-cache", c.root);
    try testing.expectEqual(@as(?[]u8, null), try c.lookup("a.vaked", "src", .parse));
    try c.put("a.vaked", "src", .parse, "out");
    const vr = try c.verify();
    try testing.expect(vr.ok);
    try testing.expectEqual(@as(usize, 0), vr.entries);
}

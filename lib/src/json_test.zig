// GENESIS_SEAL: 7c242080
const std = @import("std");
const testing = std.testing;
const json = @import("json.zig");

test "Value null" {
    const v = json.Value{ .null = {} };
    const out = try v.toOwned(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("null", out);
}

test "Value bool" {
    const v = json.Value{ .bool = true };
    const out = try v.toOwned(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("true", out);
}

test "Value int" {
    const v = json.Value{ .int = 42 };
    const out = try v.toOwned(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("42", out);
}

test "Value string with escapes" {
    const v = json.Value{ .string = "hello\"world" };
    const out = try v.toOwned(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\"hello\\\"world\"", out);
}

test "Value array" {
    const v = json.Value{ .array = &.{
        json.Value{ .int = 1 },
        json.Value{ .int = 2 },
    } };
    const out = try v.toOwned(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[1,2]", out);
}

test "Value object" {
    const v = json.Value{ .object = &.{
        .{ .key = "a", .value = json.Value{ .int = 1 } },
        .{ .key = "b", .value = json.Value{ .int = 2 } },
    } };
    const out = try v.toOwned(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"a\":1,\"b\":2}", out);
}

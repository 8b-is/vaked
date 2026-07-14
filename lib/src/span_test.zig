// GENESIS_SEAL: 7c242080
const std = @import("std");
const testing = std.testing;
const span = @import("span.zig");

test "Span construction" {
    const s = span.Span{
        .file = "test.vaked",
        .byte_start = 0,
        .byte_end = 10,
        .line = 1,
        .col = 1,
    };
    try testing.expectEqualStrings("test.vaked", s.file);
    try testing.expectEqual(@as(usize, 10), s.byte_end);
}

test "Provenance construction" {
    const p = span.Provenance{
        .file = "test.vaked",
        .decl = "fiber mediaCompress",
        .span = .{
            .file = "test.vaked",
            .byte_start = 0,
            .byte_end = 100,
            .line = 5,
            .col = 1,
        },
    };
    try testing.expectEqualStrings("fiber mediaCompress", p.decl);
}

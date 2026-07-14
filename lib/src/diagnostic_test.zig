// GENESIS_SEAL: 7c242080
const std = @import("std");
const testing = std.testing;
const diagnostic = @import("diagnostic.zig");
const span = @import("span.zig");

test "Diagnostic construction" {
    const d = diagnostic.Diagnostic{
        .code = "E-CONFORM-MISSING-FIELD",
        .message = "missing required field",
        .file = "test.vaked",
        .line = 10,
        .col = 5,
        .byte_start = 100,
        .byte_end = 110,
        .decl = "fiber mediaCompress",
        .severity = .@"error",
        .related = &.{},
    };
    try testing.expectEqual(diagnostic.Severity.@"error", d.severity);
}

test "Diagnostic sortKey" {
    const d1 = diagnostic.Diagnostic{
        .code = "E-001",
        .message = "first",
        .file = "a.vaked",
        .line = 1,
        .col = 1,
        .byte_start = 0,
        .byte_end = 10,
        .decl = "runtime",
        .severity = .@"error",
        .related = &.{},
    };
    const d2 = diagnostic.Diagnostic{
        .code = "E-002",
        .message = "second",
        .file = "a.vaked",
        .line = 2,
        .col = 1,
        .byte_start = 20,
        .byte_end = 30,
        .decl = "runtime",
        .severity = .warning,
        .related = &.{},
    };
    try testing.expect(d1.sortKey() < d2.sortKey());
}

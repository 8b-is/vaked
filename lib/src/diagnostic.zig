// GENESIS_SEAL: 7c242080
const span = @import("span.zig");

pub const Severity = enum { @"error", warning, info, hint };

pub const Related = struct {
    file: []const u8,
    decl: []const u8,
    span: span.Span,
    message: []const u8,
};

pub const Diagnostic = struct {
    code: []const u8,
    message: []const u8,
    file: []const u8,
    line: usize,
    col: usize,
    byte_start: usize,
    byte_end: usize,
    decl: []const u8,
    severity: Severity,
    related: []const Related,

    pub fn sortKey(self: Diagnostic) u64 {
        var key: u64 = 0;
        key = @as(u64, @intCast(self.line)) << 32;
        key |= @as(u64, @intCast(self.col)) << 16;
        const sev_int: u64 = @intFromEnum(self.severity);
        key |= sev_int;
        return key;
    }
};

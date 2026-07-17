// GENESIS_SEAL: 7c242080
const std = @import("std");

pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    array: []const Value,
    object: []const Entry,

    pub const Entry = struct {
        key: []const u8,
        value: Value,
    };

    /// Write `self` as JSON. "Canonical" here means: no whitespace, and
    /// object entry order IS emit order — canonicality is the producer's
    /// job (sort keys before constructing the Value; this writer never
    /// reorders).
    ///
    /// Floats must be finite: NaN/inf have no JSON representation and would
    /// emit invalid output, so finiteness is asserted in safe builds.
    pub fn writeCanonical(self: Value, writer: anytype) !void {
        switch (self) {
            .null => try writer.writeAll("null"),
            .bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .int => |i| try writer.printInt(i, 10, .lower, .{}),
            .float => |f| {
                std.debug.assert(std.math.isFinite(f));
                try writer.print("{d}", .{f});
            },
            .string => |s| try writeEscapedString(s, writer),
            .array => |arr| {
                try writer.writeByte('[');
                for (arr, 0..) |v, i| {
                    if (i > 0) try writer.writeByte(',');
                    try v.writeCanonical(writer);
                }
                try writer.writeByte(']');
            },
            .object => |obj| {
                try writer.writeByte('{');
                for (obj, 0..) |e, i| {
                    if (i > 0) try writer.writeByte(',');
                    try writeEscapedString(e.key, writer);
                    try writer.writeByte(':');
                    try e.value.writeCanonical(writer);
                }
                try writer.writeByte('}');
            },
        }
    }

    /// Shared string-escape path for values AND object keys — a key
    /// containing `"` or a control char must escape identically to a value.
    fn writeEscapedString(s: []const u8, writer: anytype) !void {
        try writer.writeByte('"');
        for (s) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                0x08 => try writer.writeAll("\\b"),
                0x0c => try writer.writeAll("\\f"),
                else => {
                    if (c < 0x20) {
                        try writer.print("\\u{x:0>4}", .{c});
                    } else {
                        try writer.writeByte(c);
                    }
                },
            }
        }
        try writer.writeByte('"');
    }

    pub fn toOwned(self: Value, allocator: std.mem.Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        try self.writeCanonical(&aw.writer);
        return aw.toOwnedSlice();
    }
};

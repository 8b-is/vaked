//! Canonical JSON — byte-identical to the Python reference (vakedc/emit.py).
//!
//! This is the single source of byte-parity with `vakedc`: every emitted graph
//! and cache record routes through `Value.writeCanonical`. The rules:
//!   - objects are emitted in INSERTION ORDER (the writer never sorts) — the
//!     reference uses a fixed key order for the structural wrappers (node:
//!     id,kind,name,labels,props,provenance; edge: from,to,label,props;
//!     provenance: file,decl,span; span: byteStart,byteEnd,line,col);
//!   - only the `props` subtree is key-sorted, which the caller does explicitly
//!     via `sortRecursive` before serializing (so prop keys and every nested
//!     object/record inside props come out lexicographically ordered);
//!   - arrays preserve insertion order;
//!   - compact separators `,` and `:` (no spaces);
//!   - strings escaped exactly like CPython's json: \" \\ \b \f \n \r \t and
//!     \u00XX for other control chars; `/` is NOT escaped; non-ASCII bytes pass
//!     through verbatim (ensure_ascii=False);
//!   - integers printed bare; we never emit floats from the graph layer.
//!
//! `Value` is an arena-allocated tagged union; build it, then serialize.

const std = @import("std");

pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    string: []const u8,
    array: []const Value,
    /// Insertion order is preserved in the slice; keys are sorted at write time.
    object: []const Entry,

    pub const Entry = struct {
        key: []const u8,
        value: Value,
    };

    pub fn writeCanonical(self: Value, w: anytype) !void {
        switch (self) {
            .null => try w.writeAll("null"),
            .bool => |b| try w.writeAll(if (b) "true" else "false"),
            .int => |n| try w.print("{d}", .{n}),
            .string => |s| try writeString(s, w),
            .array => |items| {
                try w.writeByte('[');
                for (items, 0..) |item, i| {
                    if (i != 0) try w.writeByte(',');
                    try item.writeCanonical(w);
                }
                try w.writeByte(']');
            },
            .object => |entries| {
                // Emit in insertion order; sorting (when wanted) is applied to
                // the props subtree beforehand via sortRecursive.
                try w.writeByte('{');
                for (entries, 0..) |e, i| {
                    if (i != 0) try w.writeByte(',');
                    try writeString(e.key, w);
                    try w.writeByte(':');
                    try e.value.writeCanonical(w);
                }
                try w.writeByte('}');
            },
        }
    }

    /// Recursively sort object keys lexicographically (byte == code-point order
    /// for ASCII keys). Mutates the (arena-allocated) Value tree in place. Used
    /// on `props` values so they match the reference's recursive key sort, while
    /// the structural wrappers keep their fixed insertion order.
    pub fn sortRecursive(self: *Value) void {
        switch (self.*) {
            .object => |entries| {
                const mut: []Entry = @constCast(entries);
                std.sort.pdq(Entry, mut, {}, lessEntry);
                for (mut) |*e| e.value.sortRecursive();
            },
            .array => |items| {
                const mut: []Value = @constCast(items);
                for (mut) |*v| v.sortRecursive();
            },
            else => {},
        }
    }

    fn lessEntry(_: void, a: Entry, b: Entry) bool {
        return std.mem.lessThan(u8, a.key, b.key);
    }

    /// Serialize to an owned, arena-allocated byte slice (no trailing newline).
    pub fn toOwned(self: Value, allocator: std.mem.Allocator) ![]u8 {
        var aw = std.Io.Writer.Allocating.init(allocator);
        errdefer aw.deinit();
        try self.writeCanonical(&aw.writer);
        return aw.toOwnedSlice();
    }
};

fn writeString(s: []const u8, w: anytype) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            0x08 => try w.writeAll("\\b"),
            0x09 => try w.writeAll("\\t"),
            0x0a => try w.writeAll("\\n"),
            0x0c => try w.writeAll("\\f"),
            0x0d => try w.writeAll("\\r"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    // ASCII printable and raw UTF-8 continuation/lead bytes pass
                    // through unchanged (ensure_ascii=False).
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

// ---- tests ---------------------------------------------------------------

test "writer preserves insertion order" {
    const a = std.testing.allocator;
    const v = Value{ .object = &.{
        .{ .key = "id", .value = .{ .string = "x" } },
        .{ .key = "kind", .value = .{ .string = "engine" } },
    } };
    const out = try v.toOwned(a);
    defer a.free(out);
    try std.testing.expectEqualStrings("{\"id\":\"x\",\"kind\":\"engine\"}", out);
}

test "sortRecursive sorts props subtree (record before ref)" {
    const a = std.testing.allocator;
    var entries = [_]Value.Entry{
        .{ .key = "ref", .value = .{ .string = "zig.build" } },
        .{ .key = "record", .value = .{ .array = &.{} } },
    };
    var v = Value{ .object = &entries };
    v.sortRecursive();
    const out = try v.toOwned(a);
    defer a.free(out);
    try std.testing.expectEqualStrings("{\"record\":[],\"ref\":\"zig.build\"}", out);
}

test "string escaping matches CPython json (no slash escape, control -> \\u)" {
    const a = std.testing.allocator;
    const v = Value{ .string = "a/b\n\t\"x\"\\\u{01}" };
    const out = try v.toOwned(a);
    defer a.free(out);
    try std.testing.expectEqualStrings("\"a/b\\n\\t\\\"x\\\"\\\\\\u0001\"", out);
}

test "int and bool and null" {
    const a = std.testing.allocator;
    const v = Value{ .array = &.{ .{ .int = 10 }, .{ .bool = true }, .null } };
    const out = try v.toOwned(a);
    defer a.free(out);
    try std.testing.expectEqualStrings("[10,true,null]", out);
}

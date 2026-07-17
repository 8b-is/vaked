// GENESIS_SEAL: 7c242080
//! vakedz.emit — deterministic serialization of an LPG (port of
//! vakedc/emit.py `to_canonical_json`, byte-parity with Python).
//!
//! Python serialization settings being mirrored (emit.py):
//!   json.dumps(doc, separators=(",", ":"), ensure_ascii=False) + "\n"
//! i.e. compact separators, NO ASCII-escaping of non-ASCII (raw UTF-8
//! passthrough — exactly `lib.json.Value.writeCanonical`), no indent, one
//! trailing newline. Object key order:
//!   * fixed per emit.py: doc {version,source,nodes,edges}; node
//!     {id,kind,name,labels,props,provenance}; edge {from,to,label,props};
//!     provenance {file,decl,span}; span {byteStart,byteEnd,line,col} —
//!     note: NO `file` key inside span;
//!   * recursively SORTED inside props values (emit.py `_canon_value`) —
//!     Python sorts str keys by code point, which equals byte order on
//!     UTF-8, so `std.mem.order` matches.
//! Ordering: nodes by id (`Graph.nodes_sorted`); edges by (from, label, to,
//! props-json) where the tiebreak is Python's
//! `json.dumps(props, sort_keys=True, ensure_ascii=False)` — DEFAULT
//! separators `(", ", ": ")`, reproduced by `stablePropsKey` below. Both
//! sorts are stable, like Python's.
//!
//! Floats: the resolver never produces `json.Value.float` (number literals
//! stay strings), so no Python-repr float formatting is required for
//! parity; `writeCanonical` would assert on non-finite floats anyway.
//!
//! SQLite (emit.py `to_sqlite` / `canonical_dump`) is DEFERRED — see
//! `sqlite_deferred` below. Zig's stdlib has no SQLite and external
//! dependencies are forbidden in vakedz; there is intentionally NO fake
//! implementation here.
//!
//! Memory: everything returned is allocated from the caller's allocator —
//! pass an arena. No process-exit or IO here (that contract lives in
//! main.zig).
const std = @import("std");
const lib = @import("lib");
const graphmod = lib.graph;
const json = lib.json;
const span = lib.span;

/// SQLite graph serialization (vakedc `--sqlite` / .vaked/graph.db) is not
/// implemented: Zig's stdlib has no SQLite driver and vakedz is stdlib-only.
/// TODO(task-11-followup): revisit when a vetted in-tree SQLite writer (or a
/// relaxed dependency policy) exists; until then `vakedz parse --sqlite`
/// exits 2 with a clear message (see main.zig runParse).
pub const sqlite_deferred = true;

/// emit.py `to_canonical_json`: the canonical, deterministic JSON document
/// for `g`, byte-identical to `python3 -m vakedc parse` output.
/// `source_file` is the path exactly as passed on the CLI (Python
/// `Graph.source_file`). Caller owns the returned bytes (arena-allocate).
pub fn toCanonicalJson(a: std.mem.Allocator, g: *const graphmod.Graph, source_file: []const u8) error{OutOfMemory}![]u8 {
    // nodes_sorted(): all nodes ordered by id
    const nodes = try a.alloc(graphmod.GraphNode, g.nodes.count());
    {
        var it = g.nodes.valueIterator();
        var i: usize = 0;
        while (it.next()) |n| : (i += 1) nodes[i] = n.*;
    }
    std.sort.block(graphmod.GraphNode, nodes, {}, nodeIdLess);

    // edges_sorted(): (from, label, to, props-json) with a STABLE sort
    const sortable = try a.alloc(SortableEdge, g.edges.items.len);
    for (g.edges.items, 0..) |e, i| {
        sortable[i] = .{ .edge = e, .props_key = try stablePropsKey(a, e.props) };
    }
    std.sort.block(SortableEdge, sortable, {}, edgeLess);

    // assemble the document Value with all producer-side ordering applied,
    // then let writeCanonical stream it compactly
    const node_vals = try a.alloc(json.Value, nodes.len);
    for (nodes, 0..) |n, i| node_vals[i] = try nodeValue(a, n);
    const edge_vals = try a.alloc(json.Value, sortable.len);
    for (sortable, 0..) |se, i| edge_vals[i] = try edgeValue(a, se.edge);

    const doc_entries = try a.alloc(json.Value.Entry, 4);
    doc_entries[0] = .{ .key = "version", .value = .{ .int = 1 } };
    doc_entries[1] = .{ .key = "source", .value = .{ .string = source_file } };
    doc_entries[2] = .{ .key = "nodes", .value = .{ .array = node_vals } };
    doc_entries[3] = .{ .key = "edges", .value = .{ .array = edge_vals } };
    const doc = json.Value{ .object = doc_entries };

    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    doc.writeCanonical(&aw.writer) catch return error.OutOfMemory;
    aw.writer.writeByte('\n') catch return error.OutOfMemory;
    return aw.toOwnedSlice() catch return error.OutOfMemory;
}

fn nodeIdLess(_: void, x: graphmod.GraphNode, y: graphmod.GraphNode) bool {
    return std.mem.order(u8, x.id, y.id) == .lt;
}

const SortableEdge = struct {
    edge: graphmod.GraphEdge,
    props_key: []const u8,
};

fn edgeLess(_: void, x: SortableEdge, y: SortableEdge) bool {
    const so = std.mem.order(u8, x.edge.source, y.edge.source);
    if (so != .eq) return so == .lt;
    const lo = std.mem.order(u8, x.edge.label, y.edge.label);
    if (lo != .eq) return lo == .lt;
    const to = std.mem.order(u8, x.edge.target, y.edge.target);
    if (to != .eq) return to == .lt;
    return std.mem.order(u8, x.props_key, y.props_key) == .lt;
}

/// emit.py `_canon_node`: fixed key order, props canonicalized, provenance
/// object (or null) with the span reduced to {byteStart,byteEnd,line,col}.
fn nodeValue(a: std.mem.Allocator, n: graphmod.GraphNode) error{OutOfMemory}!json.Value {
    const labels = try a.alloc(json.Value, n.labels.len);
    for (n.labels, 0..) |l, i| labels[i] = .{ .string = l };
    const e = try a.alloc(json.Value.Entry, 6);
    e[0] = .{ .key = "id", .value = .{ .string = n.id } };
    e[1] = .{ .key = "kind", .value = .{ .string = n.kind } };
    e[2] = .{ .key = "name", .value = .{ .string = n.name } };
    e[3] = .{ .key = "labels", .value = .{ .array = labels } };
    e[4] = .{ .key = "props", .value = try canonValue(a, n.props) };
    e[5] = .{ .key = "provenance", .value = try provValue(a, n.provenance) };
    return .{ .object = e };
}

fn provValue(a: std.mem.Allocator, prov: ?span.Provenance) error{OutOfMemory}!json.Value {
    const p = prov orelse return .null;
    const sp = try a.alloc(json.Value.Entry, 4);
    sp[0] = .{ .key = "byteStart", .value = .{ .int = @intCast(p.span.byte_start) } };
    sp[1] = .{ .key = "byteEnd", .value = .{ .int = @intCast(p.span.byte_end) } };
    sp[2] = .{ .key = "line", .value = .{ .int = @intCast(p.span.line) } };
    sp[3] = .{ .key = "col", .value = .{ .int = @intCast(p.span.col) } };
    const e = try a.alloc(json.Value.Entry, 3);
    e[0] = .{ .key = "file", .value = .{ .string = p.file } };
    e[1] = .{ .key = "decl", .value = .{ .string = p.decl } };
    e[2] = .{ .key = "span", .value = .{ .object = sp } };
    return .{ .object = e };
}

/// emit.py `_canon_edge`: fixed key order {from,to,label,props}.
fn edgeValue(a: std.mem.Allocator, e: graphmod.GraphEdge) error{OutOfMemory}!json.Value {
    const entries = try a.alloc(json.Value.Entry, 4);
    entries[0] = .{ .key = "from", .value = .{ .string = e.source } };
    entries[1] = .{ .key = "to", .value = .{ .string = e.target } };
    entries[2] = .{ .key = "label", .value = .{ .string = e.label } };
    entries[3] = .{ .key = "props", .value = try canonValue(a, e.props) };
    return .{ .object = entries };
}

/// emit.py `_canon_value`: recursively sort object keys (byte order ==
/// Python's code-point order on UTF-8); arrays keep source order; scalars
/// pass through. Returns a rebuilt Value — the input is never mutated.
fn canonValue(a: std.mem.Allocator, v: json.Value) error{OutOfMemory}!json.Value {
    switch (v) {
        .object => |obj| {
            const out = try a.alloc(json.Value.Entry, obj.len);
            for (obj, 0..) |e, i| {
                out[i] = .{ .key = e.key, .value = try canonValue(a, e.value) };
            }
            std.sort.block(json.Value.Entry, out, {}, entryKeyLess);
            return .{ .object = out };
        },
        .array => |arr| {
            const out = try a.alloc(json.Value, arr.len);
            for (arr, 0..) |x, i| out[i] = try canonValue(a, x);
            return .{ .array = out };
        },
        else => return v,
    }
}

fn entryKeyLess(_: void, x: json.Value.Entry, y: json.Value.Entry) bool {
    return std.mem.order(u8, x.key, y.key) == .lt;
}

/// graph.py `_stable_props_key`: the edge-sort tiebreak string
/// `json.dumps(props, sort_keys=True, ensure_ascii=False)` — Python's
/// DEFAULT separators `(", ", ": ")` (unlike the compact document), keys
/// sorted, same string escaping as json.dumps.
fn stablePropsKey(a: std.mem.Allocator, props: json.Value) error{OutOfMemory}![]const u8 {
    const canon = try canonValue(a, props);
    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    writeSpaced(canon, &aw.writer) catch return error.OutOfMemory;
    return aw.toOwnedSlice() catch return error.OutOfMemory;
}

/// Write `v` like Python json.dumps with default separators (", " / ": ")
/// and ensure_ascii=False. Only used for the edge tiebreak key; entry order
/// is emit order (callers pass canonValue output).
fn writeSpaced(v: json.Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .int => |i| try w.printInt(i, 10, .lower, .{}),
        .float => |f| {
            std.debug.assert(std.math.isFinite(f));
            try w.print("{d}", .{f});
        },
        .string => |s| try writeEscapedString(s, w),
        .array => |arr| {
            try w.writeByte('[');
            for (arr, 0..) |x, i| {
                if (i > 0) try w.writeAll(", ");
                try writeSpaced(x, w);
            }
            try w.writeByte(']');
        },
        .object => |obj| {
            try w.writeByte('{');
            for (obj, 0..) |e, i| {
                if (i > 0) try w.writeAll(", ");
                try writeEscapedString(e.key, w);
                try w.writeAll(": ");
                try writeSpaced(e.value, w);
            }
            try w.writeByte('}');
        },
    }
}

/// Same escaping as lib.json.Value.writeCanonical (private there) and
/// Python json.dumps with ensure_ascii=False: named escapes for the JSON
/// shorthands, \u00xx for remaining control bytes, raw UTF-8 passthrough
/// otherwise.
fn writeEscapedString(s: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0c => try w.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

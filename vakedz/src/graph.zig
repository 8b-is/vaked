//! Graph builder + canonical emit — AST → Labeled Property Graph → byte-exact
//! JSON, faithful to vakedc/resolve.py + vakedc/graph.py + vakedc/emit.py.
//!
//! Node id: "<basename>#<chain joined by '/'>"  (basename, not full path).
//! Provenance.file: the full source path as passed on the CLI.
//! Edge labels: contains | imports | depends_on | member_of | requires_capability
//!              | routes_to.
//! Dep-bearing fields (a bare ref ⇒ depends_on edge): source, input, output,
//! engine, from. `fibers` ⇒ member_of; `capabilities` ⇒ requires_capability.
//! Output: {"version":1,"source":..,"nodes":[..sorted by id..],"edges":[..sorted
//! by (from,label,to,props)..]} with a trailing newline. Props subtrees are
//! key-sorted; structural wrappers keep fixed order.

const std = @import("std");
const p = @import("parser.zig");
const json = @import("json.zig");
const V = json.Value;

const DEP_FIELDS = [_][]const u8{ "source", "input", "output", "engine", "from" };

fn isDepField(name: []const u8) bool {
    for (DEP_FIELDS) |f| {
        if (std.mem.eql(u8, f, name)) return true;
    }
    return false;
}

fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

const NodeRec = struct { id: []const u8, value: V };
const EdgeRec = struct { from: []const u8, label: []const u8, to: []const u8, props: V, propskey: []const u8 };

pub const Builder = struct {
    a: std.mem.Allocator,
    source: []const u8, // full path (provenance.file)
    base: []const u8, // basename for ids
    nodes: std.array_list.Managed(NodeRec),
    edges: std.array_list.Managed(EdgeRec),
    by_name: std.StringHashMap([]const u8),
    by_kind_name: std.StringHashMap([]const u8),
    externals: std.StringHashMap(void),

    pub fn init(a: std.mem.Allocator, source: []const u8) Builder {
        return .{
            .a = a,
            .source = source,
            .base = basename(source),
            .nodes = std.array_list.Managed(NodeRec).init(a),
            .edges = std.array_list.Managed(EdgeRec).init(a),
            .by_name = std.StringHashMap([]const u8).init(a),
            .by_kind_name = std.StringHashMap([]const u8).init(a),
            .externals = std.StringHashMap(void).init(a),
        };
    }

    fn nodeId(self: *Builder, chain: []const []const u8) ![]const u8 {
        const joined = try std.mem.join(self.a, "/", chain);
        return std.fmt.allocPrint(self.a, "{s}#{s}", .{ self.base, joined });
    }

    /// Pass 1: assign ids and index every decl by name and kind/name.
    fn index(self: *Builder, items: []const p.Item) !void {
        var chain = std.array_list.Managed([]const u8).init(self.a);
        defer chain.deinit();
        for (items) |it| {
            if (it == .decl) try self.indexDecl(it.decl, &chain);
        }
    }

    fn indexDecl(self: *Builder, d: *const p.Decl, chain: *std.array_list.Managed([]const u8)) !void {
        try chain.append(d.name);
        const id = try self.nodeId(chain.items);
        if (!self.by_name.contains(d.name)) try self.by_name.put(d.name, id); // keep-first
        const kn = try std.fmt.allocPrint(self.a, "{s}/{s}", .{ d.kind, d.name });
        if (!self.by_kind_name.contains(kn)) try self.by_kind_name.put(kn, id);
        for (d.body) |s| {
            if (s == .decl) try self.indexDecl(s.decl, chain);
        }
        _ = chain.pop();
    }

    /// Pass 2: build node values + edges.
    pub fn build(self: *Builder, items: []const p.Item) !void {
        try self.index(items);

        // Imports → file node + imports edges (only when imports exist).
        var has_import = false;
        for (items) |it| {
            if (it == .import) has_import = true;
        }
        const file_id = try std.fmt.allocPrint(self.a, "{s}#", .{self.base});
        if (has_import) {
            try self.nodes.append(.{ .id = file_id, .value = V{ .object = try self.dupEntries(&.{
                .{ .key = "id", .value = .{ .string = file_id } },
                .{ .key = "kind", .value = .{ .string = "file" } },
                .{ .key = "name", .value = .{ .string = self.base } },
                .{ .key = "labels", .value = .{ .array = try self.strArray(&.{"file"}) } },
                .{ .key = "props", .value = .{ .object = &.{} } },
                .{ .key = "provenance", .value = .null },
            }) } });
            for (items) |it| {
                if (it == .import) {
                    const ext = try self.external(it.import);
                    try self.addEdge(file_id, "imports", ext);
                }
            }
        }

        var chain = std.array_list.Managed([]const u8).init(self.a);
        defer chain.deinit();
        for (items) |it| {
            if (it == .decl) try self.buildDecl(it.decl, &chain, null);
        }
    }

    fn buildDecl(self: *Builder, d: *const p.Decl, chain: *std.array_list.Managed([]const u8), parent_id: ?[]const u8) !void {
        try chain.append(d.name);
        const id = try self.nodeId(chain.items);

        if (parent_id) |pid| try self.addEdge(pid, "contains", id);

        // props
        var props = std.array_list.Managed(V.Entry).init(self.a);
        if (d.signature) |sig| try props.append(.{ .key = "signature", .value = try self.encodeSig(sig) });
        if (d.annotations.len > 0) {
            var anns = std.array_list.Managed(V).init(self.a);
            for (d.annotations) |an| {
                var e = std.array_list.Managed(V.Entry).init(self.a);
                try e.append(.{ .key = "name", .value = .{ .string = an.name } });
                if (an.args) |args| {
                    try e.append(.{ .key = "args", .value = .{ .array = try self.encodeExprs(args) } });
                } else {
                    try e.append(.{ .key = "args", .value = .null });
                }
                try anns.append(.{ .object = try e.toOwnedSlice() });
            }
            try props.append(.{ .key = "annotations", .value = .{ .array = try anns.toOwnedSlice() } });
        }

        for (d.body) |s| {
            switch (s) {
                .assign => |asn| {
                    const enc = try self.encodeExpr(asn.value.*);
                    const val: V = if (std.mem.eql(u8, asn.op, "?="))
                        V{ .object = try self.dupEntries(&.{
                            .{ .key = "op", .value = .{ .string = "?=" } },
                            .{ .key = "value", .value = enc },
                        }) }
                    else
                        enc;
                    try props.append(.{ .key = asn.target, .value = val });
                    try self.fieldEdges(id, asn.target, asn.value.*);
                },
                .grant => |names| try props.append(.{ .key = "grants", .value = .{ .array = try self.strArray(names) } }),
                .order => |chains| {
                    var outer = std.array_list.Managed(V).init(self.a);
                    for (chains) |c| try outer.append(.{ .array = try self.strArray(c) });
                    try props.append(.{ .key = "order", .value = .{ .array = try outer.toOwnedSlice() } });
                },
                .open => try props.append(.{ .key = "open", .value = .{ .bool = true } }),
                .inherit => |names| try props.append(.{ .key = "inherit", .value = .{ .array = try self.strArray(names) } }),
                .field => |fd| {
                    try props.append(.{ .key = try std.fmt.allocPrint(self.a, "field:{s}", .{fd.name}), .value = try self.encodeField(fd) });
                },
                .decl => {}, // handled by recursion below
                .node => {}, // node decls: routes/contains handled elsewhere (not in v0.1 goldens)
                .edge => {},
                .app => {}, // bare config-block apps are dropped by the minimal resolver
            }
        }

        var props_val = V{ .object = try props.toOwnedSlice() };
        props_val.sortRecursive();

        const prov = V{ .object = try self.dupEntries(&.{
            .{ .key = "file", .value = .{ .string = self.source } },
            .{ .key = "decl", .value = .{ .string = try std.fmt.allocPrint(self.a, "{s} {s}", .{ d.kind, d.name }) } },
            .{ .key = "span", .value = V{ .object = try self.dupEntries(&.{
                .{ .key = "byteStart", .value = .{ .int = @intCast(d.byte_start) } },
                .{ .key = "byteEnd", .value = .{ .int = @intCast(d.byte_end) } },
                .{ .key = "line", .value = .{ .int = @intCast(d.line) } },
                .{ .key = "col", .value = .{ .int = @intCast(d.col) } },
            }) } },
        }) };

        try self.nodes.append(.{ .id = id, .value = V{ .object = try self.dupEntries(&.{
            .{ .key = "id", .value = .{ .string = id } },
            .{ .key = "kind", .value = .{ .string = d.kind } },
            .{ .key = "name", .value = .{ .string = d.name } },
            .{ .key = "labels", .value = .{ .array = try self.strArray(&.{ "decl", d.kind }) } },
            .{ .key = "props", .value = props_val },
            .{ .key = "provenance", .value = prov },
        }) } });

        for (d.body) |s| {
            if (s == .decl) try self.buildDecl(s.decl, chain, id);
        }
        _ = chain.pop();
    }

    /// Emit depends_on / member_of / requires_capability edges for a field whose
    /// value is a bare ref (or a list of bare refs).
    fn fieldEdges(self: *Builder, owner: []const u8, field: []const u8, value: p.Expr) !void {
        const label: ?[]const u8 = if (std.mem.eql(u8, field, "fibers"))
            "member_of"
        else if (std.mem.eql(u8, field, "capabilities"))
            "requires_capability"
        else if (isDepField(field))
            "depends_on"
        else
            null;
        const l = label orelse return;
        switch (value) {
            .app => |app| {
                if (app.args == null and app.record == null) {
                    try self.addEdge(owner, l, try self.resolve(app.ref));
                }
            },
            .list => |items| {
                for (items) |item| {
                    if (item == .app and item.app.args == null and item.app.record == null) {
                        try self.addEdge(owner, l, try self.resolve(item.app.ref));
                    }
                }
            },
            else => {},
        }
    }

    /// Resolve a ref to a target node id, creating an external stub if needed.
    fn resolve(self: *Builder, ref: p.Ref) ![]const u8 {
        if (ref.parts.len == 1) {
            if (self.by_name.get(ref.parts[0])) |id| return id;
            return self.external(ref.parts[0]);
        }
        if (p.isKind(ref.parts[0])) {
            const kn = try std.fmt.allocPrint(self.a, "{s}/{s}", .{ ref.parts[0], ref.parts[1] });
            if (self.by_kind_name.get(kn)) |id| return id;
        }
        const dotted = try std.mem.join(self.a, ".", ref.parts);
        return self.external(dotted);
    }

    fn external(self: *Builder, name: []const u8) ![]const u8 {
        const id = try std.fmt.allocPrint(self.a, "external:{s}", .{name});
        if (!self.externals.contains(id)) {
            try self.externals.put(id, {});
            try self.nodes.append(.{ .id = id, .value = V{ .object = try self.dupEntries(&.{
                .{ .key = "id", .value = .{ .string = id } },
                .{ .key = "kind", .value = .{ .string = "external" } },
                .{ .key = "name", .value = .{ .string = name } },
                .{ .key = "labels", .value = .{ .array = try self.strArray(&.{"external"}) } },
                .{ .key = "props", .value = V{ .object = try self.dupEntries(&.{
                    .{ .key = "external", .value = .{ .bool = true } },
                }) } },
                .{ .key = "provenance", .value = .null },
            }) } });
        }
        return id;
    }

    fn addEdge(self: *Builder, from: []const u8, label: []const u8, to: []const u8) !void {
        const props = V{ .object = &.{} };
        try self.edges.append(.{ .from = from, .label = label, .to = to, .props = props, .propskey = "{}" });
    }

    // ---- expression encoding ----
    fn encodeExpr(self: *Builder, e: p.Expr) error{OutOfMemory}!V {
        switch (e) {
            .literal => |lit| return V{ .object = try self.dupEntries(&.{
                .{ .key = "lit", .value = .{ .string = @tagName(lit.kind) } },
                .{ .key = "value", .value = .{ .string = lit.value } },
            }) },
            .list => |items| return V{ .array = try self.encodeExprs(items) },
            .record => |entries| return V{ .object = try self.dupEntries(&.{
                .{ .key = "record", .value = .{ .array = try self.encodeEntries(entries) } },
            }) },
            .app => |app| {
                var out = std.array_list.Managed(V.Entry).init(self.a);
                try out.append(.{ .key = "ref", .value = .{ .string = try ref_dotted(self.a, app.ref) } });
                if (app.args) |args| try out.append(.{ .key = "args", .value = .{ .array = try self.encodeExprs(args) } });
                if (app.record) |rec| try out.append(.{ .key = "record", .value = .{ .array = try self.encodeEntries(rec) } });
                return V{ .object = try out.toOwnedSlice() };
            },
        }
    }

    fn encodeExprs(self: *Builder, items: []const p.Expr) ![]const V {
        var out = std.array_list.Managed(V).init(self.a);
        for (items) |it| try out.append(try self.encodeExpr(it));
        return out.toOwnedSlice();
    }

    fn encodeEntries(self: *Builder, entries: []const p.RecordEntry) ![]const V {
        var out = std.array_list.Managed(V).init(self.a);
        for (entries) |e| {
            switch (e) {
                .assign => |asn| try out.append(V{ .object = try self.dupEntries(&.{
                    .{ .key = "assign", .value = .{ .string = asn.target } },
                    .{ .key = "op", .value = .{ .string = asn.op } },
                    .{ .key = "value", .value = try self.encodeExpr(asn.value.*) },
                }) }),
                .inherit => |names| try out.append(V{ .object = try self.dupEntries(&.{
                    .{ .key = "inherit", .value = .{ .array = try self.strArray(names) } },
                }) }),
            }
        }
        return out.toOwnedSlice();
    }

    fn encodeSig(self: *Builder, sig: p.Signature) !V {
        var params = std.array_list.Managed(V).init(self.a);
        for (sig.params) |param| {
            const def: V = if (param.default) |dptr| try self.encodeExpr(dptr.*) else .null;
            try params.append(V{ .object = try self.dupEntries(&.{
                .{ .key = "default", .value = def },
                .{ .key = "name", .value = .{ .string = param.name } },
                .{ .key = "type", .value = .{ .string = param.type_text } },
            }) });
        }
        const ret: V = if (sig.ret) |r| .{ .string = r } else .null;
        return V{ .object = try self.dupEntries(&.{
            .{ .key = "params", .value = .{ .array = try params.toOwnedSlice() } },
            .{ .key = "return", .value = ret },
        }) };
    }

    fn encodeField(self: *Builder, fd: p.FieldDecl) !V {
        return V{ .object = try self.dupEntries(&.{
            .{ .key = "type", .value = .{ .string = fd.type_text } },
            .{ .key = "refinements", .value = .{ .array = &.{} } }, // refinement encoding: tracked, partial in v0.1
        }) };
    }

    // ---- helpers ----
    fn dupEntries(self: *Builder, entries: []const V.Entry) ![]const V.Entry {
        return self.a.dupe(V.Entry, entries);
    }

    fn strArray(self: *Builder, items: []const []const u8) ![]const V {
        var out = std.array_list.Managed(V).init(self.a);
        for (items) |s| try out.append(.{ .string = s });
        return out.toOwnedSlice();
    }

    /// Serialize the whole graph to canonical JSON with a trailing newline.
    pub fn emit(self: *Builder) ![]u8 {
        std.sort.pdq(NodeRec, self.nodes.items, {}, lessNode);
        std.sort.pdq(EdgeRec, self.edges.items, {}, lessEdge);

        var aw = std.Io.Writer.Allocating.init(self.a);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"version\":1,\"source\":");
        try (V{ .string = self.source }).writeCanonical(w);
        try w.writeAll(",\"nodes\":[");
        for (self.nodes.items, 0..) |n, i| {
            if (i != 0) try w.writeByte(',');
            try n.value.writeCanonical(w);
        }
        try w.writeAll("],\"edges\":[");
        for (self.edges.items, 0..) |e, i| {
            if (i != 0) try w.writeByte(',');
            const ev = V{ .object = try self.dupEntries(&.{
                .{ .key = "from", .value = .{ .string = e.from } },
                .{ .key = "to", .value = .{ .string = e.to } },
                .{ .key = "label", .value = .{ .string = e.label } },
                .{ .key = "props", .value = e.props },
            }) };
            try ev.writeCanonical(w);
        }
        try w.writeAll("]}\n");
        return aw.toOwnedSlice();
    }

    fn lessNode(_: void, a: NodeRec, b: NodeRec) bool {
        return std.mem.lessThan(u8, a.id, b.id);
    }
    fn lessEdge(_: void, a: EdgeRec, b: EdgeRec) bool {
        if (!std.mem.eql(u8, a.from, b.from)) return std.mem.lessThan(u8, a.from, b.from);
        if (!std.mem.eql(u8, a.label, b.label)) return std.mem.lessThan(u8, a.label, b.label);
        if (!std.mem.eql(u8, a.to, b.to)) return std.mem.lessThan(u8, a.to, b.to);
        return std.mem.lessThan(u8, a.propskey, b.propskey);
    }
};

fn ref_dotted(a: std.mem.Allocator, ref: p.Ref) ![]const u8 {
    return std.mem.join(a, ".", ref.parts);
}

/// Full pipeline: source bytes → canonical graph JSON.
pub fn parseToGraph(a: std.mem.Allocator, source_path: []const u8, src: []const u8, err_out: *?[]const u8) !?[]u8 {
    const lex = @import("lexer.zig");
    var lx = lex.Lexer.init(a, src);
    lx.run() catch {
        if (lx.err) |e| err_out.* = std.fmt.allocPrint(a, "{s}:{d}:{d}: lex error: {s}", .{ source_path, e.line, e.col, e.msg }) catch null;
        return null;
    };
    var parser = p.Parser.init(a, lx.tokens.items);
    const items = parser.parseFile() catch {
        if (parser.err) |e| err_out.* = std.fmt.allocPrint(a, "{s}:{d}:{d}: parse error: {s}", .{ source_path, e.line, e.col, e.msg }) catch null;
        return null;
    };
    var b = Builder.init(a, source_path);
    try b.build(items);
    return try b.emit();
}

// ---- tests ---------------------------------------------------------------

test "engine decl emits a single node, zero edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\engine zigDaemon(name: String, src: Path) -> Engine {
        \\  package = zig.build {
        \\    inherit src
        \\    optimize = "ReleaseSafe"
        \\  }
        \\}
    ;
    var err: ?[]const u8 = null;
    const out = (try parseToGraph(a, "vaked/examples/engines/zig.vaked", src, &err)).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":\"zig.vaked#zigDaemon\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"edges\":[]") != null);
    // props key-sorted: record before ref inside package
    try std.testing.expect(std.mem.indexOf(u8, out, "{\"record\":[{\"inherit\":[\"src\"]}") != null);
}

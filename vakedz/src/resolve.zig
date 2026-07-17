// GENESIS_SEAL: 7c242080
//! vakedz.resolve — build the LPG from a parsed AST.
//!
//! Faithful port of vakedc/resolve.py (the semantic spec): walk the top-level
//! items in two passes — (1) *index*: pre-define all top-level decl names so
//! sibling/forward refs resolve; (2) *build*: instantiate one node per
//! declaration (byte-exact provenance attached immediately), maintain a
//! lexically-scoped symbol table, and collect refs on a worklist tagged with
//! their edge-label semantics. After the build pass the worklist is resolved
//! against the scope captured at each ref site; a ref whose head resolves to
//! no in-file declaration produces ONE external stub node per distinct dotted
//! path.
//!
//! Edge labels (by source-field semantics — only these become edges; every
//! other ref in props stays a plain value, we do NOT over-edge):
//!
//!     contains             nesting: parent decl -> child decl / node
//!     imports              a `use "<path>"` import -> external stub
//!     depends_on           refs in input / output / from / source / engine
//!     requires_capability  refs in `capabilities` lists
//!     routes_to            mesh `->` edges; the optional `:` label as a prop
//!     member_of            refs in a `parallel`'s `fibers` list
//!
//! Duplicate node ids keep the FIRST node (vakedc keep-first semantics) and
//! surface a `E-DECL-NAME-COLLISION` diagnostic (vakedc emits the same code
//! from its check stage; resolve exposes the detection directly).
//!
//! Memory: everything reachable from the returned `Result` is allocated from
//! the `buildGraph` allocator — pass an arena that outlives the result.
//! `Graph.deinit` frees only container storage.
const std = @import("std");
const parser = @import("parser.zig");
const lib = @import("lib");
const graphmod = lib.graph;
const json = lib.json;
const diagnostic = lib.diagnostic;

const empty_object: json.Value = .{ .object = &.{} };
const external_props: json.Value = .{ .object = &.{
    .{ .key = "external", .value = .{ .bool = true } },
} };

/// Fields whose ref value(s) are data-flow dependencies (resolve.py
/// `_DEPENDS_FIELDS`).
const depends_fields = [_][]const u8{ "input", "output", "from", "source", "engine" };

fn isDependsField(name: []const u8) bool {
    for (depends_fields) |f| {
        if (std.mem.eql(u8, f, name)) return true;
    }
    return false;
}

pub const Result = struct {
    graph: graphmod.Graph,
    diagnostics: []const diagnostic.Diagnostic,
};

/// A lexical scope: simple-name -> node id, with a parent link.
const Scope = struct {
    parent: ?*const Scope,
    bindings: std.StringHashMap([]const u8),

    fn lookup(self: *const Scope, name: []const u8) ?[]const u8 {
        var s: ?*const Scope = self;
        while (s) |cur| : (s = cur.parent) {
            if (cur.bindings.get(name)) |v| return v;
        }
        return null;
    }
};

/// A deferred ref resolution captured with its lexical scope
/// (resolve.py `_RefTask`). `partner` is set only for routes_to pairs.
const RefTask = struct {
    ref: parser.Ref,
    label: []const u8,
    source_id: []const u8,
    scope: *const Scope,
    partner: ?parser.Ref,
    edge_props: json.Value,
};

/// Mutable per-node props under construction; finalized into the immutable
/// `json.Value` object once the build + worklist passes are done. Mirrors
/// Python's dict semantics: `record` replaces in place (insertion order
/// kept), `appendListItem` extends a list (`setdefault(key, []).extend`).
const PropVal = union(enum) {
    value: json.Value,
    list: std.ArrayListUnmanaged(json.Value),
};

const PropEntry = struct { key: []const u8, val: PropVal };

const PropsBuilder = struct {
    entries: std.ArrayListUnmanaged(PropEntry) = .empty,

    fn record(self: *PropsBuilder, a: std.mem.Allocator, key: []const u8, value: json.Value) error{OutOfMemory}!void {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.key, key)) {
                e.val = .{ .value = value };
                return;
            }
        }
        try self.entries.append(a, .{ .key = key, .val = .{ .value = value } });
    }

    fn appendListItem(self: *PropsBuilder, a: std.mem.Allocator, key: []const u8, item: json.Value) error{OutOfMemory}!void {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.key, key)) {
                switch (e.val) {
                    .list => |*l| try l.append(a, item),
                    .value => {
                        var l: std.ArrayListUnmanaged(json.Value) = .empty;
                        try l.append(a, item);
                        e.val = .{ .list = l };
                    },
                }
                return;
            }
        }
        var l: std.ArrayListUnmanaged(json.Value) = .empty;
        try l.append(a, item);
        try self.entries.append(a, .{ .key = key, .val = .{ .list = l } });
    }

    fn finalize(self: *PropsBuilder, a: std.mem.Allocator) error{OutOfMemory}!json.Value {
        const out = try a.alloc(json.Value.Entry, self.entries.items.len);
        for (self.entries.items, 0..) |*e, i| {
            out[i] = .{ .key = e.key, .value = switch (e.val) {
                .value => |v| v,
                .list => |*l| .{ .array = try l.toOwnedSlice(a) },
            } };
        }
        return .{ .object = out };
    }
};

const Resolver = struct {
    a: std.mem.Allocator,
    /// basename for ids/provenance-decl (path-derived id stability)
    basename: []const u8,
    /// the filename as passed, for provenance/diagnostic `file` fields
    provfile: []const u8,
    g: graphmod.Graph,
    worklist: std.ArrayListUnmanaged(RefTask) = .empty,
    scopes: std.ArrayListUnmanaged(*Scope) = .empty,
    props: std.StringHashMap(*PropsBuilder),
    diags: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty,

    fn deinitInternal(self: *Resolver) void {
        self.worklist.deinit(self.a);
        self.diags.deinit(self.a);
        for (self.scopes.items) |s| {
            s.bindings.deinit();
            self.a.destroy(s);
        }
        self.scopes.deinit(self.a);
        var it = self.props.valueIterator();
        while (it.next()) |pb| {
            pb.*.entries.deinit(self.a);
            self.a.destroy(pb.*);
        }
        self.props.deinit();
    }

    fn newScope(self: *Resolver, parent: ?*const Scope) error{OutOfMemory}!*Scope {
        const s = try self.a.create(Scope);
        s.* = .{ .parent = parent, .bindings = std.StringHashMap([]const u8).init(self.a) };
        try self.scopes.append(self.a, s);
        return s;
    }

    fn nodeIdChain(self: *Resolver, chain: []const []const u8) error{OutOfMemory}![]const u8 {
        return graphmod.nodeId(self.a, self.basename, chain);
    }

    fn chainPlus(self: *Resolver, chain: []const []const u8, name: []const u8) error{OutOfMemory}![]const []const u8 {
        const out = try self.a.alloc([]const u8, chain.len + 1);
        @memcpy(out[0..chain.len], chain);
        out[chain.len] = name;
        return out;
    }

    fn builderFor(self: *Resolver, node_id: []const u8) error{OutOfMemory}!*PropsBuilder {
        const gop = try self.props.getOrPut(node_id);
        if (!gop.found_existing) {
            const pb = try self.a.create(PropsBuilder);
            pb.* = .{};
            gop.value_ptr.* = pb;
        }
        return gop.value_ptr.*;
    }

    // --- driver ----------------------------------------------------------

    fn run(self: *Resolver, items: []const parser.Item) error{OutOfMemory}!void {
        const root = try self.newScope(null);
        // pass 1 — index: pre-define all top-level decl names so
        // sibling/forward refs resolve
        for (items) |it| switch (it) {
            .decl => |d| {
                const chain = [_][]const u8{d.name};
                try root.bindings.put(d.name, try self.nodeIdChain(&chain));
            },
            .import, .comments => {},
        };
        // pass 2 — build
        for (items) |it| switch (it) {
            .decl => |d| try self.buildDecl(d, try self.chainPlus(&.{}, d.name), root, null),
            .import => |imp| try self.handleImport(imp.path),
            .comments => {},
        };
        try self.resolveWorklist();
        try self.finalizeProps();
    }

    // --- imports ---------------------------------------------------------

    fn handleImport(self: *Resolver, path: []const u8) error{OutOfMemory}!void {
        // `use "<path>"` -> imports edge from the file node to an external stub
        const file_id = try self.nodeIdChain(&.{});
        if (!self.g.hasNode(file_id)) {
            _ = try self.g.addNode(.{
                .id = file_id,
                .kind = "file",
                .name = self.basename,
                .labels = &.{"file"},
                .props = empty_object,
                .provenance = null,
            });
        }
        const stub_id = try self.ensureExternal(path);
        try self.g.addEdge(.{ .source = file_id, .target = stub_id, .label = "imports", .props = empty_object });
    }

    // --- declarations ----------------------------------------------------

    fn buildDecl(self: *Resolver, d: *const parser.Decl, chain: []const []const u8, scope: *const Scope, parent_id: ?[]const u8) error{OutOfMemory}!void {
        const nid = try self.nodeIdChain(chain);
        const labels = try self.a.alloc([]const u8, 2);
        labels[0] = "decl";
        labels[1] = d.kind;
        const inserted = try self.g.addNode(.{
            .id = nid,
            .kind = d.kind,
            .name = d.name,
            .labels = labels,
            .props = empty_object,
            .provenance = .{
                .file = self.provfile,
                .decl = try std.fmt.allocPrint(self.a, "{s} {s}", .{ d.kind, d.name }),
                .span = .{
                    .file = self.provfile,
                    .byte_start = d.byte_start,
                    .byte_end = d.byte_end,
                    .line = d.line,
                    .col = d.col,
                },
            },
        });
        if (inserted) {
            // signature/annotations seed the (surviving) node's props; on a
            // duplicate they are dropped with the rest of the node, exactly
            // like Python's discarded second GraphNode
            if (d.signature) |sig| {
                const pb = try self.builderFor(nid);
                try pb.record(self.a, "signature", try self.signatureToProps(sig));
            }
            if (d.annotations.len > 0) {
                const pb = try self.builderFor(nid);
                try pb.record(self.a, "annotations", try self.annotationsToProps(d.annotations));
            }
        } else {
            try self.addCollision(d.kind, d.name, d.byte_start, d.byte_end, d.line, d.col);
        }
        if (parent_id) |pid| {
            try self.g.addEdge(.{ .source = pid, .target = nid, .label = "contains", .props = empty_object });
        }

        // new lexical scope for the body; pre-define child decl/node names
        const child = try self.newScope(scope);
        for (d.body) |st| switch (st) {
            .decl => |inner| try child.bindings.put(inner.name, try self.nodeIdChain(try self.chainPlus(chain, inner.name))),
            .node => |n| try child.bindings.put(n.name, try self.nodeIdChain(try self.chainPlus(chain, n.name))),
            else => {},
        };
        try self.buildBody(d.kind, d.body, chain, nid, child);
    }

    fn buildBody(self: *Resolver, owner_kind: ?[]const u8, stmts: []const parser.Stmt, chain: []const []const u8, owner_id: []const u8, scope: *const Scope) error{OutOfMemory}!void {
        for (stmts) |st| switch (st) {
            .decl => |inner| try self.buildDecl(inner, try self.chainPlus(chain, inner.name), scope, owner_id),
            .node => |n| try self.buildNodeDecl(n, chain, owner_id, scope),
            .edge => |e| try self.buildEdgeStmt(e, scope, owner_id),
            .assign => |asn| try self.buildAssignment(owner_kind, asn, owner_id, scope),
            // bare app statement: no inter-node edge, no prop (keep the
            // graph minimal — resolve.py parity)
            .app => {},
            .field => |f| {
                const pb = try self.builderFor(owner_id);
                const key = try std.fmt.allocPrint(self.a, "field:{s}", .{f.name});
                try pb.record(self.a, key, try self.fieldToProps(f));
            },
            .grant => |names| try self.appendStrings(owner_id, "grants", names),
            .order => |chains| {
                const pb = try self.builderFor(owner_id);
                for (chains) |c| try pb.appendListItem(self.a, "order", try self.stringArray(c));
            },
            .open => {
                const pb = try self.builderFor(owner_id);
                try pb.record(self.a, "open", .{ .bool = true });
            },
            .inherit => |names| try self.appendStrings(owner_id, "inherit", names),
            // member decls contribute nothing to the graph (resolve.py
            // parity: MemberDecl has no _build_stmt case; the golden shows
            // namespaces with member statements and empty props)
            .member => {},
            // trivia
            .comment, .blank => {},
        };
    }

    fn buildNodeDecl(self: *Resolver, n: *const parser.NodeDecl, chain: []const []const u8, owner_id: []const u8, scope: *const Scope) error{OutOfMemory}!void {
        const nchain = try self.chainPlus(chain, n.name);
        const nid = try self.nodeIdChain(nchain);
        const inserted = try self.g.addNode(.{
            .id = nid,
            .kind = "node",
            .name = n.name,
            .labels = &.{"node"},
            .props = empty_object,
            .provenance = .{
                .file = self.provfile,
                .decl = try std.fmt.allocPrint(self.a, "node {s}", .{n.name}),
                .span = .{
                    .file = self.provfile,
                    .byte_start = n.byte_start,
                    .byte_end = n.byte_end,
                    .line = n.line,
                    .col = n.col,
                },
            },
        });
        if (!inserted) {
            try self.addCollision("node", n.name, n.byte_start, n.byte_end, n.line, n.col);
        }
        try self.g.addEdge(.{ .source = owner_id, .target = nid, .label = "contains", .props = empty_object });

        const child = try self.newScope(scope);
        for (n.body) |st| switch (st) {
            .decl => |inner| try child.bindings.put(inner.name, try self.nodeIdChain(try self.chainPlus(nchain, inner.name))),
            .node => |m| try child.bindings.put(m.name, try self.nodeIdChain(try self.chainPlus(nchain, m.name))),
            else => {},
        };
        try self.buildBody(null, n.body, nchain, nid, child);
    }

    fn buildEdgeStmt(self: *Resolver, e: parser.Edge, scope: *const Scope, owner_id: []const u8) error{OutOfMemory}!void {
        // `a -> b -> c [: "label"]` : routes_to edges along consecutive pairs
        var edge_props = empty_object;
        if (e.label) |l| {
            const obj = try self.a.alloc(json.Value.Entry, 1);
            obj[0] = .{ .key = "label", .value = .{ .string = l } };
            edge_props = .{ .object = obj };
        }
        if (e.refs.len < 2) return;
        var i: usize = 0;
        while (i < e.refs.len - 1) : (i += 1) {
            try self.worklist.append(self.a, .{
                .ref = e.refs[i],
                .label = "routes_to",
                .source_id = owner_id,
                .scope = scope,
                .partner = e.refs[i + 1],
                .edge_props = edge_props,
            });
        }
    }

    // --- assignments -----------------------------------------------------

    fn buildAssignment(self: *Resolver, owner_kind: ?[]const u8, asn: parser.Assignment, owner_id: []const u8, scope: *const Scope) error{OutOfMemory}!void {
        if (isDependsField(asn.target)) {
            try self.deferValueRefs(asn.value, "depends_on", owner_id, scope);
        } else if (std.mem.eql(u8, asn.target, "fibers") and owner_kind != null and std.mem.eql(u8, owner_kind.?, "parallel")) {
            try self.deferValueRefs(asn.value, "member_of", owner_id, scope);
        } else if (std.mem.eql(u8, asn.target, "capabilities")) {
            try self.deferValueRefs(asn.value, "requires_capability", owner_id, scope);
        }
        var prop_val = try self.valueToProps(asn.value.*);
        if (!std.mem.eql(u8, asn.op, "=")) {
            // preserve the optional-assignment operator (`?=`, set-if-unset);
            // plain `=` stays a bare value (resolve.py parity)
            const obj = try self.a.alloc(json.Value.Entry, 2);
            obj[0] = .{ .key = "op", .value = .{ .string = asn.op } };
            obj[1] = .{ .key = "value", .value = prop_val };
            prop_val = .{ .object = obj };
        }
        const pb = try self.builderFor(owner_id);
        try pb.record(self.a, asn.target, prop_val);
    }

    /// The bare-ref dependency targets in a value: the value itself if it is
    /// a bare ref-app (no args, no record), or the bare ref-app elements of a
    /// list literal. Calls, config-block apps, refs nested in records/args,
    /// and literals are NOT dependency targets (resolve.py `_refs_in_value`).
    fn deferValueRefs(self: *Resolver, v: *const parser.Expr, label: []const u8, owner_id: []const u8, scope: *const Scope) error{OutOfMemory}!void {
        switch (v.*) {
            .app => |ap| if (ap.args == null and ap.record == null) {
                try self.pushTask(ap.ref, label, owner_id, scope);
            },
            .list => |items| for (items) |it| switch (it) {
                .app => |ap| if (ap.args == null and ap.record == null) {
                    try self.pushTask(ap.ref, label, owner_id, scope);
                },
                else => {},
            },
            else => {},
        }
    }

    fn pushTask(self: *Resolver, ref: parser.Ref, label: []const u8, owner_id: []const u8, scope: *const Scope) error{OutOfMemory}!void {
        try self.worklist.append(self.a, .{
            .ref = ref,
            .label = label,
            .source_id = owner_id,
            .scope = scope,
            .partner = null,
            .edge_props = empty_object,
        });
    }

    // --- worklist resolution ----------------------------------------------

    fn resolveWorklist(self: *Resolver) error{OutOfMemory}!void {
        for (self.worklist.items) |task| {
            if (task.partner) |partner| { // routes_to pair
                const src = try self.resolveRef(task.ref, task.scope);
                const dst = try self.resolveRef(partner, task.scope);
                try self.g.addEdge(.{ .source = src, .target = dst, .label = task.label, .props = task.edge_props });
            } else {
                const tgt = try self.resolveRef(task.ref, task.scope);
                try self.g.addEdge(.{ .source = task.source_id, .target = tgt, .label = task.label, .props = task.edge_props });
            }
        }
    }

    /// Resolve a ref to a node id; unresolvable -> external stub keyed by the
    /// full dotted path. Forward refs work because scopes are fully populated
    /// before the worklist runs.
    ///
    /// Two in-file forms resolve to a declaration node:
    ///   * a bare name (`screenrec`) — looked up directly in scope;
    ///   * a `<kind>.<name>` ref (`stream.screenrec`) where `kind` is a Vaked
    ///     kind keyword and `name` resolves in scope to a declaration of that
    ///     kind.
    /// Everything else (`graph.workflow`, `fs.repo_rw`) is external.
    fn resolveRef(self: *Resolver, ref: parser.Ref, scope: *const Scope) error{OutOfMemory}![]const u8 {
        const head = ref.parts[0];
        // bare in-file name -> its decl node
        if (ref.parts.len == 1) {
            if (scope.lookup(head)) |id| return id;
            return self.ensureExternal(try ref.dotted(self.a));
        }
        // <kind>.<name> addressing of an in-file decl of that kind
        if (ref.parts.len == 2 and parser.isKind(head)) {
            if (scope.lookup(ref.parts[1])) |target_id| {
                if (self.g.getNode(target_id)) |node| {
                    if (std.mem.eql(u8, node.kind, head)) return target_id;
                }
            }
        }
        // head in-file but a dotted member: only if the exact nested id exists
        if (scope.lookup(head) != null) {
            const candidate = try self.nodeIdChain(ref.parts);
            if (self.g.hasNode(candidate)) return candidate;
        }
        return self.ensureExternal(try ref.dotted(self.a));
    }

    /// One external stub node per distinct dotted path (kind "external").
    fn ensureExternal(self: *Resolver, head_path: []const u8) error{OutOfMemory}![]const u8 {
        const id = try std.fmt.allocPrint(self.a, "external:{s}", .{head_path});
        if (self.g.hasNode(id)) return id;
        _ = try self.g.addNode(.{
            .id = id,
            .kind = "external",
            .name = head_path,
            .labels = &.{"external"},
            .props = external_props,
            .provenance = null,
        });
        return id;
    }

    // --- diagnostics -------------------------------------------------------

    fn addCollision(self: *Resolver, kind: []const u8, decl_name: []const u8, byte_start: usize, byte_end: usize, line: usize, col: usize) error{OutOfMemory}!void {
        try self.diags.append(self.a, .{
            .code = "E-DECL-NAME-COLLISION",
            .message = try std.fmt.allocPrint(
                self.a,
                "`{s} {s}` collides with an earlier declaration sharing its kind-agnostic graph id; the later one is dropped (keep-first) — rename one",
                .{ kind, decl_name },
            ),
            .file = self.provfile,
            .line = line,
            .col = col,
            .byte_start = byte_start,
            .byte_end = byte_end,
            .decl = try std.fmt.allocPrint(self.a, "{s} {s}", .{ kind, decl_name }),
            .severity = .@"error",
            .related = &.{},
        });
    }

    // --- prop helpers ------------------------------------------------------

    fn appendStrings(self: *Resolver, owner_id: []const u8, key: []const u8, names: []const []const u8) error{OutOfMemory}!void {
        const pb = try self.builderFor(owner_id);
        for (names) |nm| try pb.appendListItem(self.a, key, .{ .string = nm });
    }

    fn finalizeProps(self: *Resolver) error{OutOfMemory}!void {
        var it = self.props.iterator();
        while (it.next()) |entry| {
            if (self.g.nodes.getPtr(entry.key_ptr.*)) |node| {
                node.props = try entry.value_ptr.*.finalize(self.a);
            }
        }
    }

    // --- value -> props serialization (resolve.py `_value_to_props`) -------

    fn valueToProps(self: *Resolver, v: parser.Expr) error{OutOfMemory}!json.Value {
        return valueToPropsAlloc(self.a, v);
    }

    fn recordToProps(self: *Resolver, entries: []const parser.RecordEntry) error{OutOfMemory}!json.Value {
        return recordToPropsAlloc(self.a, entries);
    }

    fn entryToProps(self: *Resolver, e: parser.RecordEntry) error{OutOfMemory}!json.Value {
        return entryToPropsAlloc(self.a, e);
    }

    fn stringArray(self: *Resolver, names: []const []const u8) error{OutOfMemory}!json.Value {
        return stringArrayAlloc(self.a, names);
    }

    fn fieldToProps(self: *Resolver, f: parser.FieldDecl) error{OutOfMemory}!json.Value {
        const obj = try self.a.alloc(json.Value.Entry, 2);
        obj[0] = .{ .key = "type", .value = .{ .string = f.type_text } };
        const refs = try self.a.alloc(json.Value, f.refinements.len);
        for (f.refinements, 0..) |r, i| refs[i] = try self.refinementToProps(r);
        obj[1] = .{ .key = "refinements", .value = .{ .array = refs } };
        return .{ .object = obj };
    }

    /// Refinements serialize as the tuple-shaped arrays Python's parser
    /// builds: `["required"]`, `["default", <value>]`, `["cmp", op, num]`, ...
    fn refinementToProps(self: *Resolver, r: parser.Refinement) error{OutOfMemory}!json.Value {
        switch (r) {
            .required => return self.stringArray(&.{"required"}),
            .optional => return self.stringArray(&.{"optional"}),
            .nonempty => return self.stringArray(&.{"nonempty"}),
            .default => |e| {
                const arr = try self.a.alloc(json.Value, 2);
                arr[0] = .{ .string = "default" };
                arr[1] = try self.valueToProps(e.*);
                return .{ .array = arr };
            },
            .oneof => |items| {
                const arr = try self.a.alloc(json.Value, 2);
                arr[0] = .{ .string = "oneof" };
                const opts = try self.a.alloc(json.Value, items.len);
                for (items, 0..) |it, i| opts[i] = try self.valueToProps(it);
                arr[1] = .{ .array = opts };
                return .{ .array = arr };
            },
            .cmp => |c| return self.stringArray(&.{ "cmp", c.op, c.num }),
            .range => |rg| return self.stringArray(&.{ "range", rg.lo, rg.hi }),
            .matches => |m| return self.stringArray(&.{ "matches", m }),
        }
    }

    fn signatureToProps(self: *Resolver, sig: parser.Signature) error{OutOfMemory}!json.Value {
        const params = try self.a.alloc(json.Value, sig.params.len);
        for (sig.params, 0..) |p, i| {
            const pobj = try self.a.alloc(json.Value.Entry, 3);
            pobj[0] = .{ .key = "name", .value = .{ .string = p.name } };
            pobj[1] = .{ .key = "type", .value = .{ .string = p.type_text } };
            pobj[2] = .{ .key = "default", .value = if (p.default) |d| try self.valueToProps(d.*) else .null };
            params[i] = .{ .object = pobj };
        }
        const obj = try self.a.alloc(json.Value.Entry, 2);
        obj[0] = .{ .key = "params", .value = .{ .array = params } };
        obj[1] = .{ .key = "return", .value = if (sig.ret) |ret| .{ .string = ret } else .null };
        return .{ .object = obj };
    }

    fn annotationsToProps(self: *Resolver, anns: []const parser.Annotation) error{OutOfMemory}!json.Value {
        const arr = try self.a.alloc(json.Value, anns.len);
        for (anns, 0..) |ann, i| {
            const obj = try self.a.alloc(json.Value.Entry, 2);
            obj[0] = .{ .key = "name", .value = .{ .string = ann.name } };
            var args_val: json.Value = .null;
            if (ann.args) |args| {
                const av = try self.a.alloc(json.Value, args.len);
                for (args, 0..) |arg, j| av[j] = try self.valueToProps(arg);
                args_val = .{ .array = av };
            }
            obj[1] = .{ .key = "args", .value = args_val };
            arr[i] = .{ .object = obj };
        }
        return .{ .array = arr };
    }
};

// --- value -> props serialization, as free functions of the allocator ------
//
// resolve.py `_value_to_props` and friends. Factored out of `Resolver` (whose
// methods only ever threaded `self.a` through, and now delegate here) so the
// lowering driver's `enrich_graph` pass can reuse the EXACT same projection —
// vakedc does the same thing via `from .resolve import _value_to_props`.
// Behavior is unchanged: byte-for-byte the same props as before the split.

/// resolve.py `_value_to_props`.
pub fn valueToPropsAlloc(a: std.mem.Allocator, v: parser.Expr) error{OutOfMemory}!json.Value {
    switch (v) {
        .literal => |lit| {
            const obj = try a.alloc(json.Value.Entry, 2);
            obj[0] = .{ .key = "lit", .value = .{ .string = @tagName(lit.kind) } };
            obj[1] = .{ .key = "value", .value = .{ .string = lit.value } };
            return .{ .object = obj };
        },
        .list => |items| {
            const arr = try a.alloc(json.Value, items.len);
            for (items, 0..) |it, i| arr[i] = try valueToPropsAlloc(a, it);
            return .{ .array = arr };
        },
        .record => |entries| {
            const obj = try a.alloc(json.Value.Entry, 1);
            obj[0] = .{ .key = "record", .value = try recordToPropsAlloc(a, entries) };
            return .{ .object = obj };
        },
        .app => |ap| {
            var n: usize = 1;
            if (ap.args != null) n += 1;
            if (ap.record != null) n += 1;
            const obj = try a.alloc(json.Value.Entry, n);
            obj[0] = .{ .key = "ref", .value = .{ .string = try ap.ref.dotted(a) } };
            var i: usize = 1;
            if (ap.args) |args| {
                const arr = try a.alloc(json.Value, args.len);
                for (args, 0..) |arg, j| arr[j] = try valueToPropsAlloc(a, arg);
                obj[i] = .{ .key = "args", .value = .{ .array = arr } };
                i += 1;
            }
            if (ap.record) |entries| {
                obj[i] = .{ .key = "record", .value = try recordToPropsAlloc(a, entries) };
            }
            return .{ .object = obj };
        },
    }
}

fn recordToPropsAlloc(a: std.mem.Allocator, entries: []const parser.RecordEntry) error{OutOfMemory}!json.Value {
    const arr = try a.alloc(json.Value, entries.len);
    for (entries, 0..) |e, i| arr[i] = try entryToPropsAlloc(a, e);
    return .{ .array = arr };
}

fn entryToPropsAlloc(a: std.mem.Allocator, e: parser.RecordEntry) error{OutOfMemory}!json.Value {
    switch (e) {
        .assign => |asn| {
            const obj = try a.alloc(json.Value.Entry, 3);
            obj[0] = .{ .key = "assign", .value = .{ .string = asn.target } };
            obj[1] = .{ .key = "op", .value = .{ .string = asn.op } };
            obj[2] = .{ .key = "value", .value = try valueToPropsAlloc(a, asn.value.*) };
            return .{ .object = obj };
        },
        .inherit => |names| {
            const obj = try a.alloc(json.Value.Entry, 1);
            obj[0] = .{ .key = "inherit", .value = try stringArrayAlloc(a, names) };
            return .{ .object = obj };
        },
    }
}

fn stringArrayAlloc(a: std.mem.Allocator, names: []const []const u8) error{OutOfMemory}!json.Value {
    const arr = try a.alloc(json.Value, names.len);
    for (names, 0..) |nm, i| arr[i] = .{ .string = nm };
    return .{ .array = arr };
}

/// Build the LPG for one parsed file. `filename` is used as-is for
/// provenance/diagnostic `file` fields; its basename derives the stable node
/// ids (`<basename>#<outer>/<inner>`). Everything reachable from the returned
/// `Result` is allocated from `a` — pass an arena that outlives the result.
pub fn buildGraph(a: std.mem.Allocator, items: []const parser.Item, filename: []const u8) error{OutOfMemory}!Result {
    var r = Resolver{
        .a = a,
        .basename = std.fs.path.basename(filename),
        .provfile = filename,
        .g = graphmod.Graph.init(a),
        .props = std.StringHashMap(*PropsBuilder).init(a),
    };
    defer r.deinitInternal();
    errdefer r.g.deinit();

    try r.run(items);

    return .{ .graph = r.g, .diagnostics = try r.diags.toOwnedSlice(a) };
}

// GENESIS_SEAL: 7c242080
const std = @import("std");
const parser = @import("parser.zig");
pub const lib = @import("lib");
const graph = lib.graph;
const span = lib.span;

const ArrayListUnmanaged = std.ArrayListUnmanaged;

const _DEPENDS_FIELDS = [_][]const u8{ "input", "output", "from", "source", "engine" };

fn isDependsField(name: []const u8) bool {
    for (_DEPENDS_FIELDS) |f| {
        if (std.mem.eql(u8, f, name)) return true;
    }
    return false;
}

const Scope = struct {
    parent: ?*Scope,
    names: std.StringHashMap([]const u8),
    node_id: ?[]const u8,

    fn init(a: std.mem.Allocator, parent: ?*Scope, node_id: ?[]const u8) Scope {
        return .{
            .parent = parent,
            .names = std.StringHashMap([]const u8).init(a),
            .node_id = node_id,
        };
    }
    fn deinit(self: *Scope) void {
        self.names.deinit();
    }
    fn lookup(self: *const Scope, name: []const u8) ?[]const u8 {
        if (self.names.get(name)) |v| return v;
        if (self.parent) |p| return p.lookup(name);
        return null;
    }
    fn define(self: *Scope, name: []const u8, id: []const u8) !void {
        try self.names.put(name, id);
    }
};

const Deferred = struct {
    from_id: []const u8,
    ref_parts: []const []const u8,
    label: []const u8,
};

const Resolver = struct {
    a: std.mem.Allocator,
    g: *graph.Graph,
    items: []const parser.Item,
    source_path: []const u8,
    basename: []const u8,
    by_name: std.StringHashMap([]const u8),
    by_kind_name: std.StringHashMap([]const u8),
    deferred: ArrayListUnmanaged(Deferred),
    root_scope: Scope,

    fn init(a: std.mem.Allocator, g: *graph.Graph, items: []const parser.Item, source_path: []const u8) Resolver {
        const base = std.fs.path.basename(source_path);
        return .{
            .a = a,
            .g = g,
            .items = items,
            .source_path = source_path,
            .basename = base,
            .by_name = std.StringHashMap([]const u8).init(a),
            .by_kind_name = std.StringHashMap([]const u8).init(a),
            .deferred = .empty,
            .root_scope = Scope.init(a, null, null),
        };
    }

    fn deinit(self: *Resolver) void {
        self.by_name.deinit();
        self.by_kind_name.deinit();
        self.deferred.deinit(self.a);
        self.root_scope.deinit();
    }

    fn nodeIdChain(self: *Resolver, chain: []const []const u8) []const u8 {
        return graph.nodeId(self.basename, chain);
    }

    fn indexPass(self: *Resolver) !void {
        for (self.items) |item| {
            switch (item) {
                .decl => |d| {
                    const chain = [_][]const u8{d.name};
                    const id = self.nodeIdChain(&chain);
                    try self.by_name.put(d.name, id);
                    var kn_buf: [256]u8 = undefined;
                    const kn = std.fmt.bufPrint(&kn_buf, "{s}/{s}", .{ d.kind, d.name }) catch unreachable;
                    try self.by_kind_name.put(try self.a.dupe(u8, kn), id);
                    try self.root_scope.define(d.name, id);
                    try self.indexBody(d, &.{d.name});
                },
                .import => {},
            }
        }
    }

    fn indexBody(self: *Resolver, d: *const parser.Decl, chain: []const []const u8) !void {
        for (d.body) |stmt| {
            switch (stmt) {
                .decl => |inner| {
                    var new_chain = try self.a.alloc([]const u8, chain.len + 1);
                    @memcpy(new_chain[0..chain.len], chain);
                    new_chain[chain.len] = inner.name;
                    const id = self.nodeIdChain(new_chain);
                    try self.root_scope.define(inner.name, id);
                    var kn_buf: [256]u8 = undefined;
                    const kn = std.fmt.bufPrint(&kn_buf, "{s}/{s}", .{ inner.kind, inner.name }) catch unreachable;
                    try self.by_kind_name.put(try self.a.dupe(u8, kn), id);
                    try self.indexBody(inner, new_chain);
                },
                .node => |n| {
                    var new_chain = try self.a.alloc([]const u8, chain.len + 1);
                    @memcpy(new_chain[0..chain.len], chain);
                    new_chain[chain.len] = n.name;
                    const id = self.nodeIdChain(new_chain);
                    try self.root_scope.define(n.name, id);
                },
                else => {},
            }
        }
    }

    fn buildPass(self: *Resolver) !void {
        const file_id = self.nodeIdChain(&.{});
        const file_node = graph.GraphNode{
            .id = file_id,
            .kind = "file",
            .name = self.basename,
            .labels = &.{},
            .props = .null,
            .provenance = null,
        };
        try self.g.addNode(file_node);

        for (self.items) |item| {
            switch (item) {
                .decl => |d| try self.buildDecl(d),
                .import => |path| {
                    const imp_id = try std.fmt.allocPrint(self.a, "{s}#import:{s}", .{ self.basename, path });
                    const imp_node = graph.GraphNode{
                        .id = imp_id,
                        .kind = "external",
                        .name = path,
                        .labels = &.{},
                        .props = .null,
                        .provenance = null,
                    };
                    try self.g.addNode(imp_node);
                    try self.g.addEdge(.{
                        .source = file_id,
                        .target = imp_id,
                        .label = "imports",
                        .props = .null,
                    });
                },
            }
        }

        try self.resolveDeferred();
    }

    fn buildDecl(self: *Resolver, d: *const parser.Decl) !void {
        const chain = [_][]const u8{d.name};
        const id = self.nodeIdChain(&chain);
        const prov = span.Provenance{
            .file = self.source_path,
            .decl = d.name,
            .span = .{
                .file = self.source_path,
                .byte_start = d.byte_start,
                .byte_end = d.byte_end,
                .line = d.line,
                .col = d.col,
            },
        };
        const labels: []const []const u8 = &.{d.kind};
        const node = graph.GraphNode{
            .id = id,
            .kind = d.kind,
            .name = d.name,
            .labels = labels,
            .props = .null,
            .provenance = prov,
        };
        try self.g.addNode(node);

        const file_id = self.nodeIdChain(&.{});
        try self.g.addEdge(.{
            .source = file_id,
            .target = id,
            .label = "contains",
            .props = .null,
        });

        for (d.body) |stmt| {
            switch (stmt) {
                .decl => |inner| try self.buildInnerDecl(inner, id, &.{d.name}),
                .node => |n| try self.buildNode(n, id, &.{d.name}),
                .edge => |e| try self.buildEdge(e, id),
                .assign => |asgn| try self.handleAssign(asgn, id),
                .member => |m| {
                    const m_chain = [_][]const u8{ d.name, m.name };
                    const m_id = self.nodeIdChain(&m_chain);
                    try self.g.addNode(.{
                        .id = m_id,
                        .kind = "member",
                        .name = m.name,
                        .labels = &.{},
                        .props = .null,
                        .provenance = null,
                    });
                    try self.g.addEdge(.{
                        .source = m_id,
                        .target = id,
                        .label = "member_of",
                        .props = .null,
                    });
                },
                .app => |ap| try self.handleApp(ap, id),
                else => {},
            }
        }
    }

    fn buildInnerDecl(self: *Resolver, d: *const parser.Decl, parent_id: []const u8, chain: []const []const u8) !void {
        var new_chain = try self.a.alloc([]const u8, chain.len + 1);
        @memcpy(new_chain[0..chain.len], chain);
        new_chain[chain.len] = d.name;
        const id = self.nodeIdChain(new_chain);
        const prov = span.Provenance{
            .file = self.source_path,
            .decl = d.name,
            .span = .{
                .file = self.source_path,
                .byte_start = d.byte_start,
                .byte_end = d.byte_end,
                .line = d.line,
                .col = d.col,
            },
        };
        try self.g.addNode(.{
            .id = id,
            .kind = d.kind,
            .name = d.name,
            .labels = &.{d.kind},
            .props = .null,
            .provenance = prov,
        });
        try self.g.addEdge(.{
            .source = parent_id,
            .target = id,
            .label = "contains",
            .props = .null,
        });
        for (d.body) |stmt| {
            switch (stmt) {
                .decl => |inner| try self.buildInnerDecl(inner, id, new_chain),
                .node => |n| try self.buildNode(n, id, new_chain),
                .edge => |e| try self.buildEdge(e, id),
                .assign => |asgn| try self.handleAssign(asgn, id),
                else => {},
            }
        }
    }

    fn buildNode(self: *Resolver, n: *const parser.NodeDecl, parent_id: []const u8, chain: []const []const u8) !void {
        var new_chain = try self.a.alloc([]const u8, chain.len + 1);
        @memcpy(new_chain[0..chain.len], chain);
        new_chain[chain.len] = n.name;
        const id = self.nodeIdChain(new_chain);
        try self.g.addNode(.{
            .id = id,
            .kind = "node",
            .name = n.name,
            .labels = &.{},
            .props = .null,
            .provenance = null,
        });
        try self.g.addEdge(.{
            .source = parent_id,
            .target = id,
            .label = "contains",
            .props = .null,
        });
        try self.root_scope.define(n.name, id);
        for (n.body) |stmt| {
            switch (stmt) {
                .edge => |e| try self.buildEdge(e, id),
                .assign => |asgn| try self.handleAssign(asgn, id),
                else => {},
            }
        }
    }

    fn buildEdge(self: *Resolver, e: parser.Edge, from_id: []const u8) !void {
        if (e.refs.len < 2) return;
        const label = e.label orelse "depends_on";
        var i: usize = 0;
        while (i < e.refs.len - 1) : (i += 1) {
            const tgt_ref = e.refs[i + 1];
            try self.deferred.append(self.a, .{
                .from_id = from_id,
                .ref_parts = tgt_ref.parts,
                .label = label,
            });
        }
    }

    fn handleAssign(self: *Resolver, asgn: parser.Assignment, from_id: []const u8) !void {
        if (!isDependsField(asgn.target)) return;
        switch (asgn.value.*) {
            .app => |ap| {
                try self.deferred.append(self.a, .{
                    .from_id = from_id,
                    .ref_parts = ap.ref.parts,
                    .label = "depends_on",
                });
            },
            else => {},
        }
    }

    fn handleApp(self: *Resolver, ap: parser.App, from_id: []const u8) !void {
        try self.deferred.append(self.a, .{
            .from_id = from_id,
            .ref_parts = ap.ref.parts,
            .label = "depends_on",
        });
    }

    fn resolveDeferred(self: *Resolver) !void {
        for (self.deferred.items) |d| {
            const target_name = d.ref_parts[d.ref_parts.len - 1];
            var target_id: ?[]const u8 = null;

            if (self.root_scope.lookup(target_name)) |id| {
                target_id = id;
            } else if (d.ref_parts.len > 1) {
                const kn = try std.mem.join(self.a, "/", d.ref_parts);
                if (self.by_kind_name.get(kn)) |id| {
                    target_id = id;
                }
            }

            if (target_id == null) {
                const ext_id = try std.fmt.allocPrint(self.a, "{s}#external/{s}", .{ self.basename, target_name });
                if (!self.g.hasNode(ext_id)) {
                    try self.g.addNode(.{
                        .id = ext_id,
                        .kind = "external",
                        .name = target_name,
                        .labels = &.{},
                        .props = .null,
                        .provenance = null,
                    });
                }
                target_id = ext_id;
            }

            try self.g.addEdge(.{
                .source = d.from_id,
                .target = target_id.?,
                .label = d.label,
                .props = .null,
            });
        }
    }
};

pub fn buildGraph(a: std.mem.Allocator, items: []const parser.Item, source_path: []const u8) !graph.Graph {
    var g = graph.Graph.init(a);
    errdefer g.deinit();

    var r = Resolver.init(a, &g, items, source_path);
    defer r.deinit();

    try r.indexPass();
    try r.buildPass();

    return g;
}

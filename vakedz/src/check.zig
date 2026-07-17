// GENESIS_SEAL: 7c242080
//! vakedz.check — 0011 type-system checker: FULL parity with vakedc/check.py.
//!
//! Slice 2 (this file is now the complete port; the differential harness
//! tools/check-diff/run.sh runs with NO allowlist):
//!
//!   * Capabilities (§4, check.py `_check_mesh` and friends): E-CAP-UNKNOWN-
//!     DOMAIN/-GRANT, E-CAP-ATTENUATION (§4.4), E-CAP-USE (§4.3),
//!     W-POLA-EXCESS, W-CONFUSED-DEPUTY — the ≤-closure is computed once at
//!     capability well-formedness time and kept on the spec (`leq`).
//!   * Egress (#226/0026, `_check_egress_use`): E-EGRESS-USE,
//!     W-EGRESS-UNREFINED, incl. Python-`ipaddress` loopback/private
//!     classification of membrane allow-hosts.
//!   * Closed-world ref resolution (#7, `_check_ref_resolution`):
//!     E-REF-UNRESOLVED over the depends-ref walk (topology kinds deferred),
//!     branch-B namespace heads (runtime-scoped first, then the builtin
//!     catalog), 3-part accessor refs, and `use`-import Stage-2 binding
//!     (`_collect_import_decls` — the checker's only IO beyond builtins,
//!     injected via ImportReader).
//!   * Workflow (#27, `_check_workflow`): agent-target E-REF-UNRESOLVED,
//!     E-WORKFLOW-CYCLE (byte-identical cycle path via the same DFS),
//!     E-WORKFLOW-DEPTH, E-DETERMINISM-EFFECT (#224).
//!   * eBPF (#225, `_check_ebpf_intent`): E-EBPF-UNKNOWN-HOOK,
//!     E-EBPF-BAD-INTENT, E-EBPF-ENFORCE-ON-OBSERVE.
//!   * Generics (§5, `_check_generics`): E-GENERIC-INCONSISTENT.
//!   * Message parity: list/record values and grant lists render through a
//!     Python-repr-compatible renderer (reprStr/vpropRepr) — the exact text
//!     `repr(_value_to_props(v))` produces.
//!
//! Slice 1 (conformance core), still here:
//!
//!   * Stage 3 (elaborate): schema / capability / namespace registry built by
//!     parsing `vaked/schema/builtins.vaked` through the vakedz parser and
//!     folding in user `schema` / `capability` / `namespace` decls (user
//!     overrides builtin by name) — check.py `_Registry` / `_load_decls_into`.
//!   * Load-time well-formedness (check.py `_check_schema_wellformed`,
//!     `_check_capability_wellformed`, `_check_namespace_wellformed`):
//!     E-SCHEMA-REFINEMENT, E-SCHEMA-BAD-REGEX, E-SCHEMA-BAD-ONEOF,
//!     E-SCHEMA-BAD-RANGE, E-SCHEMA-BAD-DEFAULT, E-CAP-ORDER-DANGLING,
//!     E-CAP-ORDER-CYCLE.
//!   * Conformance (§1.1, check.py `_conform_decl` / `_conform_node` /
//!     `_conform_nested_record`): E-CONFORM-MISSING-FIELD,
//!     E-CONFORM-UNKNOWN-FIELD, E-CONFORM-TYPE — incl. the kind→schema
//!     dispatch (`network`→`networkMembrane`), the fiber `policy`→`fiberPolicy`
//!     nested record, mesh-node bodies against `meshNode`, and workflow steps
//!     against `workflowStep`. Type matching mirrors `_value_matches_type`
//!     exactly: Int◁Float widening, Path/Duration/Bytes string forms, unions,
//!     List<T>, generic-parameter permissiveness, and the permissive pass for
//!     refs against non-scalar atoms (§2.3).
//!   * Constraints (§3, check.py `_check_field_constraints` / `_check_matches`):
//!     E-CONSTRAINT-NONEMPTY, E-CONSTRAINT-ONEOF, E-CONSTRAINT-RANGE (cmp and
//!     range forms), E-CONSTRAINT-MATCHES (bounded-dialect regex, full match).
//!   * E-DECL-NAME-COLLISION: detection lives in resolve.zig (keep-first
//!     `addNode`); this pass ENRICHES those diagnostics to check.py's richer
//!     shape (keyword-token span, Python message format, `related` pointer to
//!     the first declaration). Collisions resolve.zig reports but check.py
//!     would not (duplicate `node` names, decl-vs-node, dropped-body child
//!     collisions) are filtered out for Python parity.
//!
//! Diagnostics are sorted by (file, byteStart, byteEnd, code) with a stable
//! sort, exactly like check.py `Diagnostic.sort_key`.
//!
//! Memory: everything reachable from a returned diagnostics slice is
//! allocated from the caller's allocator — pass an arena that outlives it.
const std = @import("std");
const lex = @import("lexer.zig");
const parser = @import("parser.zig");
const resolve = @import("resolve.zig");
const lib = @import("lib");
const json = lib.json;
const diagnostic = lib.diagnostic;
const Diagnostic = diagnostic.Diagnostic;

// --------------------------------------------------------------------------- #
// Span tuple — check.py passes (byteStart, byteEnd, line, col) 4-tuples
// --------------------------------------------------------------------------- #

pub const Span4 = struct { bs: usize, be: usize, line: usize, col: usize };

fn declSpan4(d: *const parser.Decl) Span4 {
    return .{ .bs = d.byte_start, .be = d.byte_end, .line = d.line, .col = d.col };
}

fn nodeSpan4(n: *const parser.NodeDecl) Span4 {
    return .{ .bs = n.byte_start, .be = n.byte_end, .line = n.line, .col = n.col };
}

// --------------------------------------------------------------------------- #
// Source position map (check.py `_SourceMap`) — land diagnostics on the exact
// offending token within a decl's byte range
// --------------------------------------------------------------------------- #

const SourceMap = struct {
    tokens: []const lex.Token, // newline/comment/eof filtered out, source order

    fn init(a: std.mem.Allocator, src: []const u8) error{OutOfMemory}!SourceMap {
        var l = lex.Lexer.init(a, src);
        try l.run();
        var toks: std.ArrayList(lex.Token) = .empty;
        for (l.tokens.items) |t| {
            switch (t.kind) {
                .newline, .comment, .eof => {},
                else => try toks.append(a, t),
            }
        }
        return .{ .tokens = try toks.toOwnedSlice(a) };
    }

    /// Tokens with byte_start in [bs, be) — bisect on the sorted starts.
    fn toksIn(self: *const SourceMap, bs: usize, be: usize) []const lex.Token {
        return self.tokens[self.lowerBound(bs)..self.lowerBound(be)];
    }

    fn lowerBound(self: *const SourceMap, key: usize) usize {
        var lo: usize = 0;
        var hi: usize = self.tokens.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.tokens[mid].byte_start < key) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// Span of the FIRST top-level assignment / field-name identifier `name`
    /// within [ds, de) (check.py `field_name_span`).
    fn fieldNameSpan(self: *const SourceMap, ds: usize, de: usize, name: []const u8) ?Span4 {
        const toks = self.toksIn(ds, de);
        for (toks, 0..) |t, idx| {
            if (t.kind == .ident and std.mem.eql(u8, t.value, name)) {
                if (idx + 1 < toks.len) {
                    const nxt = toks[idx + 1];
                    if (nxt.kind == .op and (std.mem.eql(u8, nxt.value, "=") or
                        std.mem.eql(u8, nxt.value, "?=") or
                        std.mem.eql(u8, nxt.value, ":") or
                        std.mem.eql(u8, nxt.value, "{")))
                    {
                        return tokSpan(t);
                    }
                }
            }
        }
        return null;
    }

    /// Span of the first VALUE token of `name = <value>` within the decl
    /// range (check.py `field_value_span`); falls back to the field name.
    fn fieldValueSpan(self: *const SourceMap, ds: usize, de: usize, name: []const u8) ?Span4 {
        const toks = self.toksIn(ds, de);
        for (toks, 0..) |t, idx| {
            if (t.kind == .ident and std.mem.eql(u8, t.value, name)) {
                if (idx + 1 < toks.len) {
                    const nxt = toks[idx + 1];
                    if (nxt.kind == .op and (std.mem.eql(u8, nxt.value, "=") or
                        std.mem.eql(u8, nxt.value, "?=")))
                    {
                        if (idx + 2 < toks.len) return tokSpan(toks[idx + 2]);
                    }
                }
            }
        }
        return self.fieldNameSpan(ds, de, name);
    }

    /// Span of a decl's leading keyword token (check.py `_span_of_decl_kw`).
    fn declKwSpan(self: *const SourceMap, d_bs: usize, d_be: usize, kind: []const u8) ?Span4 {
        const toks = self.toksIn(d_bs, d_be);
        for (toks) |t| {
            if (t.kind == .ident and std.mem.eql(u8, t.value, kind)) return tokSpan(t);
        }
        return null;
    }
};

fn tokSpan(t: lex.Token) Span4 {
    return .{ .bs = t.byte_start, .be = t.byte_end, .line = t.line, .col = t.col };
}

// --------------------------------------------------------------------------- #
// Scalar / type-atom vocabulary (check.py `_SCALARS`, `_STRING_ALIASES`,
// `_GENERIC_PARAMS`)
// --------------------------------------------------------------------------- #

fn isScalar(atom: []const u8) bool {
    const scalars = [_][]const u8{ "String", "Int", "Float", "Bool", "Path", "Duration", "Bytes", "Null" };
    for (scalars) |s| if (std.mem.eql(u8, s, atom)) return true;
    return false;
}

fn isStringAlias(atom: []const u8) bool {
    return std.mem.eql(u8, atom, "Strategy") or std.mem.eql(u8, atom, "View");
}

fn isGenericParam(atom: []const u8) bool {
    if (std.mem.eql(u8, atom, "Node") or std.mem.eql(u8, atom, "Edge")) return true;
    return atom.len == 1 and atom[0] >= 'A' and atom[0] <= 'Z';
}

// --------------------------------------------------------------------------- #
// Type-text helpers (check.py `_base_type`, `_split_union`,
// `_is_numeric_type`)
// --------------------------------------------------------------------------- #

const BaseType = struct { inner: []const u8, is_list: bool };

fn baseType(type_text: []const u8) BaseType {
    const t = std.mem.trim(u8, type_text, " \t");
    if (std.mem.startsWith(u8, t, "List<") and std.mem.endsWith(u8, t, ">")) {
        return .{ .inner = std.mem.trim(u8, t["List<".len .. t.len - 1], " \t"), .is_list = true };
    }
    return .{ .inner = t, .is_list = false };
}

fn isNumericType(type_text: []const u8) bool {
    const inner = baseType(type_text).inner;
    const numeric = [_][]const u8{ "Int", "Float", "Duration", "Bytes" };
    for (numeric) |n| if (std.mem.eql(u8, n, inner)) return true;
    return false;
}

/// Split a union type on top-level '|' (not inside '<...>').
fn splitUnion(a: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var depth: usize = 0;
    var start: usize = 0;
    for (text, 0..) |ch, i| {
        switch (ch) {
            '<' => depth += 1,
            '>' => depth -|= 1,
            '|' => if (depth == 0) {
                try parts.append(a, text[start..i]);
                start = i + 1;
            },
            else => {},
        }
    }
    try parts.append(a, text[start..]);
    return parts.toOwnedSlice(a);
}

// --------------------------------------------------------------------------- #
// Registry (check.py Stage 3 — elaborate)
// --------------------------------------------------------------------------- #

const Presence = enum { required, optional };

pub const FieldSpec = struct {
    name: []const u8,
    type_text: []const u8,
    refinements: []const parser.Refinement,
    presence: Presence,
    has_default: bool,
};

pub const SchemaSpec = struct {
    name: []const u8,
    fields: []FieldSpec, // insertion-ordered; rebinding a name replaced in place
    field_idx: std.StringHashMapUnmanaged(usize), // name -> index into fields
    open: bool,
    origin_file: []const u8,
    decl_span: Span4,

    fn getField(self: *const SchemaSpec, name: []const u8) ?*const FieldSpec {
        const i = self.field_idx.get(name) orelse return null;
        return &self.fields[i];
    }
};

/// The reflexive-transitive `<=` closure of one capability domain's declared
/// order chains (check.py `CapabilitySpec.leq`, a dict grant -> upward set).
pub const Leq = struct {
    nodes: []const []const u8, // grants ∪ chain-named, first-seen order
    reach: []const []const bool, // reach[i][j] ⇔ nodes[i] <= nodes[j]

    fn indexOf(self: *const Leq, name: []const u8) ?usize {
        for (self.nodes, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
        return null;
    }

    /// check.py `_leq(cap, a, b)` — is `b in cap.leq.get(a, {a})`?
    pub fn leq(self: *const Leq, x: []const u8, y: []const u8) bool {
        const ix = self.indexOf(x) orelse return std.mem.eql(u8, x, y);
        const iy = self.indexOf(y) orelse return false;
        return self.reach[ix][iy];
    }
};

pub const CapabilitySpec = struct {
    domain: []const u8,
    grants: []const []const u8, // dedup'd, insertion order (Python: set)
    order_chains: []const []const []const u8,
    /// Set by checkCapabilityWellformed (Python does the same): the ≤-closure,
    /// or the identity-over-grants fallback when the order is cyclic.
    leq: ?Leq = null,
    origin_file: []const u8,
    decl_span: Span4,

    /// check.py `_leq` — `b in cap.leq.get(a, {a})`.
    fn capLeq(self: *const CapabilitySpec, x: []const u8, y: []const u8) bool {
        if (self.leq) |*l| return l.leq(x, y);
        return std.mem.eql(u8, x, y);
    }
};

pub const NamespaceSpec = struct {
    head: []const u8,
    open: bool,
    members: []const []const u8,
    origin_file: []const u8,
    decl_span: Span4,
};

pub const Registry = struct {
    a: std.mem.Allocator,
    schemas: std.ArrayList(SchemaSpec) = .empty,
    schema_idx: std.StringHashMapUnmanaged(usize) = .empty,
    caps: std.ArrayList(CapabilitySpec) = .empty,
    cap_idx: std.StringHashMapUnmanaged(usize) = .empty,
    namespaces: std.ArrayList(NamespaceSpec) = .empty,
    ns_idx: std.StringHashMapUnmanaged(usize) = .empty,

    // NOTE on pointer stability: the returned pointers alias the ArrayList
    // items and are only valid once loading is complete (checkSource loads
    // everything before any check runs — same lifecycle as check.py).

    pub fn getSchema(self: *const Registry, name: []const u8) ?*const SchemaSpec {
        const i = self.schema_idx.get(name) orelse return null;
        return &self.schemas.items[i];
    }

    pub fn getCap(self: *const Registry, name: []const u8) ?*const CapabilitySpec {
        const i = self.cap_idx.get(name) orelse return null;
        return &self.caps.items[i];
    }

    pub fn getNamespace(self: *const Registry, head: []const u8) ?*const NamespaceSpec {
        const i = self.ns_idx.get(head) orelse return null;
        return &self.namespaces.items[i];
    }

    fn addSchema(self: *Registry, spec: SchemaSpec) error{OutOfMemory}!void {
        if (self.schema_idx.get(spec.name)) |i| {
            self.schemas.items[i] = spec; // later (user) overrides earlier (builtin)
            return;
        }
        try self.schema_idx.put(self.a, spec.name, self.schemas.items.len);
        try self.schemas.append(self.a, spec);
    }

    fn addCapability(self: *Registry, spec: CapabilitySpec) error{OutOfMemory}!void {
        if (self.cap_idx.get(spec.domain)) |i| {
            self.caps.items[i] = spec;
            return;
        }
        try self.cap_idx.put(self.a, spec.domain, self.caps.items.len);
        try self.caps.append(self.a, spec);
    }

    fn addNamespace(self: *Registry, spec: NamespaceSpec) error{OutOfMemory}!void {
        if (self.ns_idx.get(spec.head)) |i| {
            self.namespaces.items[i] = spec;
            return;
        }
        try self.ns_idx.put(self.a, spec.head, self.namespaces.items.len);
        try self.namespaces.append(self.a, spec);
    }
};

/// check.py `_presence_of` — required unless `optional` or a `default`.
fn presenceOf(refinements: []const parser.Refinement) struct { presence: Presence, has_default: bool } {
    var has_default = false;
    var has_optional = false;
    for (refinements) |r| switch (r) {
        .default => has_default = true,
        .optional => has_optional = true,
        else => {},
    };
    const presence: Presence = if (has_optional or has_default) .optional else .required;
    return .{ .presence = presence, .has_default = has_default };
}

fn schemaFromDecl(a: std.mem.Allocator, d: *const parser.Decl, filename: []const u8) error{OutOfMemory}!SchemaSpec {
    var fields: std.ArrayList(FieldSpec) = .empty;
    var field_idx: std.StringHashMapUnmanaged(usize) = .empty;
    var is_open = false;
    for (d.body) |st| switch (st) {
        .field => |f| {
            const p = presenceOf(f.refinements);
            const spec = FieldSpec{
                .name = f.name,
                .type_text = f.type_text,
                .refinements = f.refinements,
                .presence = p.presence,
                .has_default = p.has_default,
            };
            if (field_idx.get(f.name)) |i| {
                fields.items[i] = spec; // dict semantics: rebind keeps position
            } else {
                try field_idx.put(a, f.name, fields.items.len);
                try fields.append(a, spec);
            }
        },
        .open => is_open = true,
        else => {},
    };
    return .{
        .name = d.name,
        .fields = try fields.toOwnedSlice(a),
        .field_idx = field_idx,
        .open = is_open,
        .origin_file = filename,
        .decl_span = declSpan4(d),
    };
}

fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

fn capabilityFromDecl(a: std.mem.Allocator, d: *const parser.Decl, filename: []const u8) error{OutOfMemory}!CapabilitySpec {
    var grants: std.ArrayList([]const u8) = .empty;
    var chains: std.ArrayList([]const []const u8) = .empty;
    for (d.body) |st| switch (st) {
        .grant => |names| for (names) |nm| {
            if (!containsString(grants.items, nm)) try grants.append(a, nm);
        },
        .order => |cs| for (cs) |c| try chains.append(a, c),
        else => {},
    };
    return .{
        .domain = d.name,
        .grants = try grants.toOwnedSlice(a),
        .order_chains = try chains.toOwnedSlice(a),
        .origin_file = filename,
        .decl_span = declSpan4(d),
    };
}

fn namespaceFromDecl(a: std.mem.Allocator, d: *const parser.Decl, filename: []const u8) error{OutOfMemory}!NamespaceSpec {
    var is_open = false;
    var members: std.ArrayList([]const u8) = .empty;
    for (d.body) |st| switch (st) {
        .open => is_open = true,
        .member => |m| if (!containsString(members.items, m.name)) try members.append(a, m.name),
        else => {},
    };
    return .{
        .head = d.name,
        .open = is_open,
        .members = try members.toOwnedSlice(a),
        .origin_file = filename,
        .decl_span = declSpan4(d),
    };
}

fn loadDeclsInto(reg: *Registry, items: []const parser.Item, filename: []const u8) error{OutOfMemory}!void {
    for (items) |it| switch (it) {
        .decl => |d| {
            if (std.mem.eql(u8, d.kind, "schema")) {
                try reg.addSchema(try schemaFromDecl(reg.a, d, filename));
            } else if (std.mem.eql(u8, d.kind, "capability")) {
                try reg.addCapability(try capabilityFromDecl(reg.a, d, filename));
            } else if (std.mem.eql(u8, d.kind, "namespace")) {
                try reg.addNamespace(try namespaceFromDecl(reg.a, d, filename));
            }
        },
        else => {},
    };
}

// --------------------------------------------------------------------------- #
// Literal / value matching (check.py `_literal_matches_scalar`,
// `_value_matches_type`, `_value_matches_atom`, `_record_conforms`)
// --------------------------------------------------------------------------- #

fn literalMatchesScalar(kind: parser.LitKind, value: []const u8, type_atom: []const u8) bool {
    if (isGenericParam(type_atom)) return true; // §5: a type parameter matches any value
    if (isStringAlias(type_atom)) return kind == .string;
    if (!isScalar(type_atom)) return false; // literals only match scalar atoms
    if (std.mem.eql(u8, type_atom, "Null")) return kind == .null;
    if (std.mem.eql(u8, type_atom, "String")) return kind == .string;
    if (std.mem.eql(u8, type_atom, "Bool")) return kind == .bool;
    if (std.mem.eql(u8, type_atom, "Int"))
        return kind == .number and std.mem.indexOfScalar(u8, value, '.') == null;
    if (std.mem.eql(u8, type_atom, "Float")) return kind == .number; // Int◁Float widening
    if (std.mem.eql(u8, type_atom, "Path")) return kind == .path or kind == .string; // §2.5
    if (std.mem.eql(u8, type_atom, "Duration")) return kind == .duration or kind == .string;
    if (std.mem.eql(u8, type_atom, "Bytes")) return kind == .bytes or kind == .string;
    return false;
}

/// check.py `_literal_matches_type` — NOTE: bug-compatibly splits arms on a
/// PLAIN '|' (not depth-aware), exactly like the Python `inner.split("|")`.
fn literalMatchesType(kind: parser.LitKind, value: []const u8, type_text: []const u8) bool {
    const b = baseType(type_text);
    if (b.is_list) return false; // a scalar literal never matches a List type
    var it = std.mem.splitScalar(u8, b.inner, '|');
    while (it.next()) |arm0| {
        const arm = std.mem.trim(u8, arm0, " \t");
        if (literalMatchesScalar(kind, value, arm)) return true;
    }
    return false;
}

fn valueMatchesType(a: std.mem.Allocator, reg: *const Registry, v: parser.Expr, type_text: []const u8) error{OutOfMemory}!bool {
    const b = baseType(type_text);
    if (b.is_list) {
        switch (v) {
            .list => |items| {
                for (items) |e| {
                    if (!try valueMatchesType(a, reg, e, b.inner)) return false;
                }
                return true;
            },
            else => return false,
        }
    }
    const arms = try splitUnion(a, b.inner);
    for (arms) |arm| {
        if (try valueMatchesAtom(a, reg, v, std.mem.trim(u8, arm, " \t"))) return true;
    }
    return false;
}

fn valueMatchesAtom(a: std.mem.Allocator, reg: *const Registry, v: parser.Expr, atom: []const u8) error{OutOfMemory}!bool {
    const ab = baseType(atom);
    if (ab.is_list) return valueMatchesType(a, reg, v, atom);
    // a generic type parameter matches any value (§5)
    if (isGenericParam(ab.inner)) return true;
    switch (v) {
        .literal => |l| return literalMatchesScalar(l.kind, l.value, ab.inner),
        // a list value only matches a List atom (handled above)
        .list => return false,
        // ref / app value: cannot match a scalar atom; a non-scalar atom is a
        // permissive pass (§2.3 — the referent's type cannot be disproven)
        .app => return !(isScalar(ab.inner) or isStringAlias(ab.inner)),
        .record => |entries| {
            if (isScalar(ab.inner) or isStringAlias(ab.inner)) return false;
            if (reg.getSchema(ab.inner)) |sch| return recordConforms(a, reg, entries, sch);
            return true;
        },
    }
}

/// check.py `_record_conforms` — best-effort structural conformance of a
/// record VALUE to a named schema (nested diagnostics stay with the owner).
fn recordConforms(a: std.mem.Allocator, reg: *const Registry, entries: []const parser.RecordEntry, schema: *const SchemaSpec) error{OutOfMemory}!bool {
    var present = Bindings{};
    for (entries) |e| switch (e) {
        .assign => |asn| try present.put(a, asn.target, asn.value.*),
        .inherit => {},
    };
    for (schema.fields) |f| {
        if (f.presence == .required and present.get(f.name) == null) return false;
    }
    if (!schema.open) {
        for (present.entries.items) |e| {
            if (schema.getField(e.name) == null) return false;
        }
    }
    for (present.entries.items) |e| {
        if (schema.getField(e.name)) |f| {
            if (!try valueMatchesType(a, reg, e.value, f.type_text)) return false;
        }
    }
    return true;
}

// --------------------------------------------------------------------------- #
// Field bindings (check.py `_decl_field_bindings` / `_node_bindings`) —
// dict semantics: rebind keeps first position, `order` records every
// occurrence in source order
// --------------------------------------------------------------------------- #

const Bound = struct { name: []const u8, value: parser.Expr };

const Bindings = struct {
    entries: std.ArrayList(Bound) = .empty,
    order: std.ArrayList([]const u8) = .empty,

    fn put(self: *Bindings, a: std.mem.Allocator, name: []const u8, value: parser.Expr) error{OutOfMemory}!void {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.name, name)) {
                e.value = value;
                return;
            }
        }
        try self.entries.append(a, .{ .name = name, .value = value });
    }

    fn putOrdered(self: *Bindings, a: std.mem.Allocator, name: []const u8, value: parser.Expr) error{OutOfMemory}!void {
        try self.put(a, name, value);
        try self.order.append(a, name);
    }

    fn get(self: *const Bindings, name: []const u8) ?parser.Expr {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.name, name)) return e.value;
        }
        return null;
    }
};

fn declFieldBindings(a: std.mem.Allocator, body: []const parser.Stmt) error{OutOfMemory}!Bindings {
    var b = Bindings{};
    for (body) |st| switch (st) {
        .assign => |asn| try b.putOrdered(a, asn.target, asn.value.*),
        .app => |ap| {
            // a named config block in field position, e.g. `policy { … }`
            if (ap.record != null and ap.args == null and ap.ref.parts.len == 1) {
                try b.putOrdered(a, ap.ref.parts[0], .{ .record = ap.record.? });
            }
        },
        else => {},
    };
    return b;
}

fn nodeBindings(a: std.mem.Allocator, body: []const parser.Stmt) error{OutOfMemory}!Bindings {
    var b = Bindings{};
    for (body) |st| switch (st) {
        .assign => |asn| try b.putOrdered(a, asn.target, asn.value.*),
        else => {},
    };
    return b;
}

// --------------------------------------------------------------------------- #
// Rendering helpers (check.py `_render_literal`, `_render_vprop`,
// `_render_oneof`, `_fmtnum`, `_num`)
// --------------------------------------------------------------------------- #

fn num(s: []const u8) ?f64 {
    return std.fmt.parseFloat(f64, s) catch null;
}

fn fmtNum(a: std.mem.Allocator, v: f64) error{OutOfMemory}![]const u8 {
    if (v == @floor(v) and @abs(v) < 9007199254740992.0) {
        return std.fmt.allocPrint(a, "{d}", .{@as(i64, @intFromFloat(v))});
    }
    return std.fmt.allocPrint(a, "{d}", .{v});
}

fn renderLiteral(a: std.mem.Allocator, lit: parser.Literal) error{OutOfMemory}![]const u8 {
    if (lit.kind == .string) return std.fmt.allocPrint(a, "\"{s}\"", .{lit.value});
    return lit.value;
}

/// Python `repr()` of a str, for the value shapes that reach diagnostic
/// messages. Quote choice (single unless the string contains `'` and no
/// `"`), backslash/quote escaping, \n \r \t, and \xHH for other control
/// bytes. Printable non-ASCII passes through byte-for-byte (Python keeps
/// printable Unicode literal in repr; Vaked sources are UTF-8).
fn reprStr(a: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]const u8 {
    const has_sq = std.mem.indexOfScalar(u8, s, '\'') != null;
    const has_dq = std.mem.indexOfScalar(u8, s, '"') != null;
    const q: u8 = if (has_sq and !has_dq) '"' else '\'';
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, q);
    for (s) |c| {
        if (c == '\\') {
            try out.appendSlice(a, "\\\\");
        } else if (c == q) {
            try out.append(a, '\\');
            try out.append(a, c);
        } else if (c == '\n') {
            try out.appendSlice(a, "\\n");
        } else if (c == '\r') {
            try out.appendSlice(a, "\\r");
        } else if (c == '\t') {
            try out.appendSlice(a, "\\t");
        } else if (c < 0x20 or c == 0x7f) {
            try out.appendSlice(a, try std.fmt.allocPrint(a, "\\x{x:0>2}", .{c}));
        } else {
            try out.append(a, c);
        }
    }
    try out.append(a, q);
    return out.toOwnedSlice(a);
}

/// Python `repr()` of a list of str — `['a', 'b']` / `[]`.
fn reprStrList(a: std.mem.Allocator, items: []const []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '[');
    for (items, 0..) |s, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, try reprStr(a, s));
    }
    try out.append(a, ']');
    return out.toOwnedSlice(a);
}

/// Python `repr()` of resolve._value_to_props(v) — the exact text check.py's
/// `_render_vprop` embeds for list/record values. Dict key order follows
/// _value_to_props insertion order; every leaf value is a str (the parser
/// stores all literal values as source text), and vprop `lit` kinds are
/// lowercased (`v.kind.lower()`), which @tagName matches exactly.
fn vpropRepr(a: std.mem.Allocator, out: *std.ArrayList(u8), v: parser.Expr) error{OutOfMemory}!void {
    switch (v) {
        .literal => |l| {
            try out.appendSlice(a, "{'lit': ");
            try out.appendSlice(a, try reprStr(a, @tagName(l.kind)));
            try out.appendSlice(a, ", 'value': ");
            try out.appendSlice(a, try reprStr(a, l.value));
            try out.append(a, '}');
        },
        .list => |items| {
            try out.append(a, '[');
            for (items, 0..) |e, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try vpropRepr(a, out, e);
            }
            try out.append(a, ']');
        },
        .record => |entries| {
            try out.appendSlice(a, "{'record': ");
            try vpropReprEntries(a, out, entries);
            try out.append(a, '}');
        },
        .app => |ap| {
            try out.appendSlice(a, "{'ref': ");
            try out.appendSlice(a, try reprStr(a, try ap.ref.dotted(a)));
            if (ap.args) |args| {
                try out.appendSlice(a, ", 'args': [");
                for (args, 0..) |arg, i| {
                    if (i > 0) try out.appendSlice(a, ", ");
                    try vpropRepr(a, out, arg);
                }
                try out.append(a, ']');
            }
            if (ap.record) |rec| {
                try out.appendSlice(a, ", 'record': ");
                try vpropReprEntries(a, out, rec);
            }
            try out.append(a, '}');
        },
    }
}

fn vpropReprEntries(a: std.mem.Allocator, out: *std.ArrayList(u8), entries: []const parser.RecordEntry) error{OutOfMemory}!void {
    try out.append(a, '[');
    for (entries, 0..) |e, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        switch (e) {
            .assign => |asn| {
                try out.appendSlice(a, "{'assign': ");
                try out.appendSlice(a, try reprStr(a, asn.target));
                try out.appendSlice(a, ", 'op': ");
                try out.appendSlice(a, try reprStr(a, asn.op));
                try out.appendSlice(a, ", 'value': ");
                try vpropRepr(a, out, asn.value.*);
                try out.append(a, '}');
            },
            .inherit => |names| {
                try out.appendSlice(a, "{'inherit': ");
                try out.appendSlice(a, try reprStrList(a, names));
                try out.append(a, '}');
            },
        }
    }
    try out.append(a, ']');
}

/// check.py `_render_vprop` — literals render bare (strings double-quoted),
/// apps render as the dotted ref (`"ref" in vprop` wins even with args or a
/// record attached), and lists/records fall through to Python `repr()` of the
/// value-prop structure (vpropRepr).
fn renderValue(a: std.mem.Allocator, v: parser.Expr) error{OutOfMemory}![]const u8 {
    switch (v) {
        .literal => |l| return renderLiteral(a, l),
        .app => |ap| return ap.ref.dotted(a),
        .list, .record => {
            var out: std.ArrayList(u8) = .empty;
            try vpropRepr(a, &out, v);
            return out.toOwnedSlice(a);
        },
    }
}

// --------------------------------------------------------------------------- #
// Bounded-dialect regex (0011 §3.5) — dialect validation (load-time) and a
// Pike-VM full matcher (check-time). check.py validates with
// `_regex_dialect_error` and matches with `re.fullmatch`.
// --------------------------------------------------------------------------- #

/// Port of check.py `_regex_dialect_error` — returns an explanatory message
/// if the literal (slashes included) leaves the bounded dialect, else null.
fn regexDialectError(a: std.mem.Allocator, regex_literal: []const u8) error{OutOfMemory}!?[]const u8 {
    var body = regex_literal;
    if (body.len >= 2 and body[0] == '/' and body[body.len - 1] == '/') {
        body = body[1 .. body.len - 1];
    }
    var i: usize = 0;
    const n = body.len;
    var in_class = false;
    while (i < n) {
        const c = body[i];
        if (c == '\\') {
            if (i + 1 >= n) return "trailing backslash";
            const nxt = body[i + 1];
            if (nxt >= '1' and nxt <= '9') {
                return try std.fmt.allocPrint(a, "backreference (\\{c}) is not in the bounded dialect", .{nxt});
            }
            i += 2;
            continue;
        }
        if (in_class) {
            if (c == ']') in_class = false;
            i += 1;
            continue;
        }
        if (c == '[') {
            in_class = true;
            i += 1;
            continue;
        }
        if (c == '(') {
            if (i + 1 < n and body[i + 1] == '?') {
                // rendered as a SLICE so a pattern ending in `(?` formats as
                // an empty string, exactly like Python's `body[i+2:i+3]`
                const kind_s: []const u8 = if (i + 2 < n) body[i + 2 .. i + 3] else "";
                const kind: u8 = if (kind_s.len == 1) kind_s[0] else 0;
                if (kind == '=' or kind == '!') {
                    return try std.fmt.allocPrint(a, "lookahead ((?{c}…)) is not in the bounded dialect", .{kind});
                }
                if (kind == '<') {
                    const nxt2: u8 = if (i + 3 < n) body[i + 3] else 0;
                    if (nxt2 == '=' or nxt2 == '!') {
                        return try std.fmt.allocPrint(a, "lookbehind ((?<{c}…)) is not in the bounded dialect", .{nxt2});
                    }
                    return "named group ((?<…>)) is not in the bounded dialect";
                }
                if (kind == 'P') return "named group ((?P…)) is not in the bounded dialect";
                if (kind == '>') return "atomic group ((?>…)) is not in the bounded dialect";
                if (kind == ':') {
                    i += 3; // non-capturing group is fine
                    continue;
                }
                return try std.fmt.allocPrint(a, "extended group ((?{s}…)) is not in the bounded dialect", .{kind_s});
            }
            i += 1;
            continue;
        }
        i += 1;
    }
    if (in_class) return "unterminated character class '['";
    return null;
}

const Rx = struct {
    const ClassItem = union(enum) {
        range: [2]u8,
        digit,
        nondigit,
        word,
        nonword,
        space,
        nonspace,
    };
    const Class = struct { negated: bool, items: []const ClassItem };

    const Node = union(enum) {
        alt: []const *const Node,
        cat: []const *const Node,
        rep: struct { child: *const Node, min: u32, max: ?u32 },
        char: u8,
        any,
        class: Class,
        start,
        end,
        wordb, // \b
        nwordb, // \B
        empty,
    };

    const Inst = union(enum) {
        char: u8,
        any,
        class: Class,
        split: [2]u32,
        jmp: u32,
        assert_start,
        assert_end,
        assert_wordb,
        assert_nwordb,
        match,
    };

    const ParseState = struct {
        a: std.mem.Allocator,
        pat: []const u8,
        i: usize = 0,

        fn peek(self: *ParseState) ?u8 {
            return if (self.i < self.pat.len) self.pat[self.i] else null;
        }

        fn node(self: *ParseState, n: Node) error{ OutOfMemory, BadRegex }!*const Node {
            const p = try self.a.create(Node);
            p.* = n;
            return p;
        }

        fn parseAlt(self: *ParseState) error{ OutOfMemory, BadRegex }!*const Node {
            var alts: std.ArrayList(*const Node) = .empty;
            try alts.append(self.a, try self.parseCat());
            while (self.peek() == '|') {
                self.i += 1;
                try alts.append(self.a, try self.parseCat());
            }
            if (alts.items.len == 1) return alts.items[0];
            return self.node(.{ .alt = try alts.toOwnedSlice(self.a) });
        }

        fn parseCat(self: *ParseState) error{ OutOfMemory, BadRegex }!*const Node {
            var seq: std.ArrayList(*const Node) = .empty;
            while (self.peek()) |c| {
                if (c == '|' or c == ')') break;
                try seq.append(self.a, try self.parsePiece());
            }
            if (seq.items.len == 0) return self.node(.empty);
            if (seq.items.len == 1) return seq.items[0];
            return self.node(.{ .cat = try seq.toOwnedSlice(self.a) });
        }

        fn parsePiece(self: *ParseState) error{ OutOfMemory, BadRegex }!*const Node {
            const atom = try self.parseAtom();
            const rep = (try self.parseQuantifier(atom)) orelse return atom;
            // A trailing '?' makes the quantifier lazy (`a+?`, `a{1,2}?`).
            // For pure acceptance (fullmatch yes/no) lazy ≡ greedy, so it is
            // swallowed — it must NOT fall through as a literal '?' atom.
            if (self.peek() == '?') self.i += 1;
            // Multiple-repeat fence: another quantifier directly after a
            // (possibly lazy) quantifier — `a**`, `a++`, `a+?*`, `a{2}*`,
            // `a*{2}` — is re.error "multiple repeat" in CPython (or, ≥3.11,
            // possessive semantics for `?+`/`*+`/`++`). Both are
            // non-equivalent to treating the second mark as a literal, so
            // refuse the pattern (BadRegex → the check-time caller skips).
            if (self.peek()) |c2| {
                if (c2 == '?' or c2 == '*' or c2 == '+') return error.BadRegex;
                if (c2 == '{') {
                    // only a well-formed {m}/{m,n}/{m,} counts as a quantifier
                    // (parseQuantifier restores i when it is a literal '{')
                    if (try self.parseQuantifier(rep) != null) return error.BadRegex;
                }
            }
            return rep;
        }

        fn parseQuantifier(self: *ParseState, atom: *const Node) error{ OutOfMemory, BadRegex }!?*const Node {
            const c = self.peek() orelse return null;
            switch (c) {
                '?' => {
                    self.i += 1;
                    return try self.node(.{ .rep = .{ .child = atom, .min = 0, .max = 1 } });
                },
                '*' => {
                    self.i += 1;
                    return try self.node(.{ .rep = .{ .child = atom, .min = 0, .max = null } });
                },
                '+' => {
                    self.i += 1;
                    return try self.node(.{ .rep = .{ .child = atom, .min = 1, .max = null } });
                },
                '{' => {
                    // {m} | {m,n} | {m,} — anything else is a literal '{'
                    const save = self.i;
                    self.i += 1;
                    const m = self.parseInt() orelse {
                        self.i = save;
                        return null;
                    };
                    var max: ?u32 = m;
                    if (self.peek() == ',') {
                        self.i += 1;
                        max = self.parseInt(); // null ⇒ open-ended {m,}
                    }
                    if (self.peek() != '}') {
                        self.i = save;
                        return null;
                    }
                    self.i += 1;
                    return try self.node(.{ .rep = .{ .child = atom, .min = m, .max = max } });
                },
                else => return null,
            }
        }

        fn parseInt(self: *ParseState) ?u32 {
            var v: u32 = 0;
            var any = false;
            while (self.peek()) |c| {
                if (c < '0' or c > '9') break;
                v = v *| 10 +| (c - '0');
                self.i += 1;
                any = true;
            }
            return if (any) v else null;
        }

        fn parseAtom(self: *ParseState) error{ OutOfMemory, BadRegex }!*const Node {
            const c = self.peek() orelse return error.BadRegex;
            switch (c) {
                '(' => {
                    self.i += 1;
                    // skip the (?: marker of a non-capturing group
                    if (self.i + 1 < self.pat.len and self.pat[self.i] == '?' and self.pat[self.i + 1] == ':') {
                        self.i += 2;
                    }
                    const inner = try self.parseAlt();
                    if (self.peek() != ')') return error.BadRegex;
                    self.i += 1;
                    return inner;
                },
                '[' => {
                    self.i += 1;
                    return self.node(.{ .class = try self.parseClass() });
                },
                '.' => {
                    self.i += 1;
                    return self.node(.any);
                },
                '^' => {
                    self.i += 1;
                    return self.node(.start);
                },
                '$' => {
                    self.i += 1;
                    return self.node(.end);
                },
                '\\' => {
                    self.i += 1;
                    const e = self.peek() orelse return error.BadRegex;
                    self.i += 1;
                    if (perlClass(e)) |item| {
                        const items = try self.a.alloc(ClassItem, 1);
                        items[0] = item;
                        return self.node(.{ .class = .{ .negated = false, .items = items } });
                    }
                    // `\0` followed by an octal digit is an OCTAL escape in
                    // Python (`\07` is BEL, `\012` is LF) — unsupported here.
                    // Compiling it as NUL + literal digit would silently
                    // mis-check, so refuse (BadRegex → the caller skips).
                    if (e == '0') {
                        if (self.peek()) |d| {
                            if (d >= '0' and d <= '7') return error.BadRegex;
                        }
                    }
                    return switch (e) {
                        'b' => self.node(.wordb),
                        'B' => self.node(.nwordb),
                        // under fullmatch semantics \A ≡ ^ and \Z ≡ $
                        'A' => self.node(.start),
                        'Z' => self.node(.end),
                        'x' => self.node(.{ .char = try self.hexEscape() }),
                        else => self.node(.{ .char = escapeChar(e) orelse return error.BadRegex }),
                    };
                },
                ')' => return error.BadRegex,
                else => {
                    self.i += 1;
                    return self.node(.{ .char = c });
                },
            }
        }

        fn parseClass(self: *ParseState) error{ OutOfMemory, BadRegex }!Class {
            var negated = false;
            var items: std.ArrayList(ClassItem) = .empty;
            if (self.peek() == '^') {
                negated = true;
                self.i += 1;
            }
            var first = true;
            while (true) {
                const c = self.peek() orelse return error.BadRegex;
                if (c == ']' and !first) break;
                first = false;
                var lo: u8 = undefined;
                if (c == '\\') {
                    self.i += 1;
                    const e = self.peek() orelse return error.BadRegex;
                    self.i += 1;
                    if (perlClass(e)) |item| {
                        try items.append(self.a, item);
                        continue;
                    }
                    lo = try self.classEscapeChar(e);
                } else {
                    lo = c;
                    self.i += 1;
                }
                // range?
                if (self.peek() == '-' and self.i + 1 < self.pat.len and self.pat[self.i + 1] != ']') {
                    self.i += 1;
                    const hc = self.peek() orelse return error.BadRegex;
                    var hi: u8 = undefined;
                    if (hc == '\\') {
                        self.i += 1;
                        const e = self.peek() orelse return error.BadRegex;
                        self.i += 1;
                        hi = try self.classEscapeChar(e);
                    } else {
                        hi = hc;
                        self.i += 1;
                    }
                    // Python rejects inverted ranges (`[z-a]` → re.error), and
                    // the check-time caller skips on error — mirror that
                    // instead of compiling a never-matching range.
                    if (lo > hi) return error.BadRegex;
                    try items.append(self.a, .{ .range = .{ lo, hi } });
                } else {
                    try items.append(self.a, .{ .range = .{ lo, lo } });
                }
            }
            self.i += 1; // closing ']'
            return .{ .negated = negated, .items = try items.toOwnedSlice(self.a) };
        }

        /// `\xHH` — exactly two hex digits, like Python (fewer → re.error).
        fn hexEscape(self: *ParseState) error{BadRegex}!u8 {
            if (self.i + 1 >= self.pat.len) return error.BadRegex;
            const v = std.fmt.parseInt(u8, self.pat[self.i .. self.i + 2], 16) catch return error.BadRegex;
            self.i += 2;
            return v;
        }

        /// Char-valued escape INSIDE a character class: `\b` is backspace
        /// there (Python semantics), `\xHH` is hex; the rest via escapeChar.
        /// `\0` followed by an octal digit is an octal escape in Python here
        /// too — refuse it (same divergence-safe skip as the atom position).
        fn classEscapeChar(self: *ParseState, e: u8) error{BadRegex}!u8 {
            if (e == '0') {
                if (self.peek()) |d| {
                    if (d >= '0' and d <= '7') return error.BadRegex;
                }
            }
            return switch (e) {
                'b' => 0x08,
                'x' => try self.hexEscape(),
                else => escapeChar(e) orelse error.BadRegex,
            };
        }
    };

    fn perlClass(c: u8) ?ClassItem {
        return switch (c) {
            'd' => .digit,
            'D' => .nondigit,
            'w' => .word,
            'W' => .nonword,
            's' => .space,
            'S' => .nonspace,
            else => null,
        };
    }

    /// Char-valued escapes shared by atom and class positions. Unknown
    /// ASCII-letter escapes are reserved in Python (`re.error: bad escape`) —
    /// null → BadRegex → skip, matching Python's silent re.error path
    /// (PARITY). `\1`-`\9` (backreferences in the atom position, octal in a
    /// class) also return null, but that is a deliberate skip-DIVERGENCE from
    /// Python, which compiles them: the §3.5 dialect validator already
    /// rejects backrefs at load time and vakedc now skips the
    /// matches-constraint on dialect-rejected patterns, so the divergence is
    /// unobservable through `check`. Genuinely unsupported (also null or
    /// BadRegex at the call sites): `\u`/`\U`/`\N` unicode escapes and octal
    /// `\0oo` beyond bare `\0` — Python compiles these; a value checked
    /// against such a pattern is skipped rather than mis-checked.
    fn escapeChar(c: u8) ?u8 {
        return switch (c) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'f' => 0x0c,
            'v' => 0x0b,
            'a' => 0x07,
            '0' => 0,
            else => {
                if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '1' and c <= '9')) return null;
                return c; // escaped metacharacter / punctuation → literal
            },
        };
    }

    fn classItemMatch(item: ClassItem, c: u8) bool {
        return switch (item) {
            .range => |r| c >= r[0] and c <= r[1],
            .digit => c >= '0' and c <= '9',
            .nondigit => !(c >= '0' and c <= '9'),
            .word => (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_',
            .nonword => !((c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_'),
            .space => c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c,
            .nonspace => !(c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c),
        };
    }

    fn classMatch(cls: Class, c: u8) bool {
        var any = false;
        for (cls.items) |item| {
            if (classItemMatch(item, c)) {
                any = true;
                break;
            }
        }
        return any != cls.negated;
    }

    const max_rep_copies: u32 = 1024;
    /// Total compiled-program cap. max_rep_copies bounds each repetition
    /// LEVEL only; nested counted repetitions multiply (`((a{k}){k}){k}` is
    /// k³ instructions), so the program size is capped too → BadRegex → the
    /// check-time caller skips (Python's re handles such patterns; a value
    /// checked against one is skipped rather than exhausting memory).
    const max_insts: usize = 65536;

    const Compiler = struct {
        a: std.mem.Allocator,
        prog: std.ArrayList(Inst) = .empty,

        fn pc(self: *Compiler) u32 {
            return @intCast(self.prog.items.len);
        }

        fn push(self: *Compiler, inst: Inst) error{ OutOfMemory, BadRegex }!void {
            if (self.prog.items.len >= max_insts) return error.BadRegex;
            try self.prog.append(self.a, inst);
        }

        fn emitNode(self: *Compiler, n: *const Node) error{ OutOfMemory, BadRegex }!void {
            switch (n.*) {
                .empty => {},
                .char => |c| try self.push(.{ .char = c }),
                .any => try self.push(.any),
                .class => |cls| try self.push(.{ .class = cls }),
                .start => try self.push(.assert_start),
                .end => try self.push(.assert_end),
                .wordb => try self.push(.assert_wordb),
                .nwordb => try self.push(.assert_nwordb),
                .cat => |seq| for (seq) |ch| try self.emitNode(ch),
                .alt => |alts| {
                    var jmps: std.ArrayList(u32) = .empty;
                    defer jmps.deinit(self.a);
                    var i: usize = 0;
                    while (i < alts.len) : (i += 1) {
                        if (i + 1 < alts.len) {
                            const sp = self.pc();
                            try self.push(.{ .split = .{ 0, 0 } });
                            self.prog.items[sp] = .{ .split = .{ self.pc(), 0 } };
                            try self.emitNode(alts[i]);
                            try jmps.append(self.a, self.pc());
                            try self.push(.{ .jmp = 0 });
                            self.prog.items[sp].split[1] = self.pc();
                        } else {
                            try self.emitNode(alts[i]);
                        }
                    }
                    const endpc = self.pc();
                    for (jmps.items) |j| self.prog.items[j] = .{ .jmp = endpc };
                },
                .rep => |r| {
                    if (r.min > max_rep_copies) return error.BadRegex;
                    // min mandatory copies
                    var k: u32 = 0;
                    while (k < r.min) : (k += 1) try self.emitNode(r.child);
                    if (r.max) |mx| {
                        if (mx < r.min) return error.BadRegex;
                        if (mx - r.min > max_rep_copies) return error.BadRegex;
                        // (max-min) optional greedy copies: each may bail to END
                        var splits: std.ArrayList(u32) = .empty;
                        defer splits.deinit(self.a);
                        var j: u32 = r.min;
                        while (j < mx) : (j += 1) {
                            const sp = self.pc();
                            try self.push(.{ .split = .{ 0, 0 } });
                            self.prog.items[sp] = .{ .split = .{ self.pc(), 0 } };
                            try splits.append(self.a, sp);
                            try self.emitNode(r.child);
                        }
                        const endpc = self.pc();
                        for (splits.items) |sp| self.prog.items[sp].split[1] = endpc;
                    } else {
                        // greedy star: L1: split(L2, L3); L2: e; jmp L1; L3:
                        const l1 = self.pc();
                        try self.push(.{ .split = .{ 0, 0 } });
                        self.prog.items[l1] = .{ .split = .{ self.pc(), 0 } };
                        try self.emitNode(r.child);
                        try self.push(.{ .jmp = l1 });
                        self.prog.items[l1].split[1] = self.pc();
                    }
                },
            }
        }
    };

    /// Full-match `s` against pattern `pat` (slashes already stripped).
    /// Anchoring is implicit (Python `re.fullmatch`). Returns error.BadRegex
    /// on a pattern the engine cannot compile (caller skips, like Python's
    /// silent `re.error` path).
    fn fullMatch(a: std.mem.Allocator, pat: []const u8, s: []const u8) error{ OutOfMemory, BadRegex }!bool {
        var ps = ParseState{ .a = a, .pat = pat };
        const root = try ps.parseAlt();
        if (ps.i != pat.len) return error.BadRegex;
        var comp = Compiler{ .a = a };
        try comp.emitNode(root);
        try comp.push(.match);
        const prog = comp.prog.items;

        // Pike VM without captures.
        var clist: std.ArrayList(u32) = .empty;
        var nlist: std.ArrayList(u32) = .empty;
        const on_c = try a.alloc(bool, prog.len);
        const on_n = try a.alloc(bool, prog.len);
        @memset(on_c, false);
        try addThread(prog, &clist, on_c, 0, s, 0, a);
        var pos: usize = 0;
        while (pos <= s.len) : (pos += 1) {
            var matched_here = false;
            @memset(on_n, false);
            nlist.clearRetainingCapacity();
            for (clist.items) |pcv| {
                switch (prog[pcv]) {
                    .match => {
                        if (pos == s.len) matched_here = true;
                    },
                    .char => |c| {
                        if (pos < s.len and s[pos] == c)
                            try addThread(prog, &nlist, on_n, pcv + 1, s, pos + 1, a);
                    },
                    .any => {
                        if (pos < s.len and s[pos] != '\n')
                            try addThread(prog, &nlist, on_n, pcv + 1, s, pos + 1, a);
                    },
                    .class => |cls| {
                        if (pos < s.len and classMatch(cls, s[pos]))
                            try addThread(prog, &nlist, on_n, pcv + 1, s, pos + 1, a);
                    },
                    else => {},
                }
            }
            if (pos == s.len) return matched_here;
            std.mem.swap(std.ArrayList(u32), &clist, &nlist);
        }
        return false;
    }

    fn isWordChar(c: u8) bool {
        return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }

    /// Python `\b`: a word char on exactly one side of the position.
    fn wordBoundary(s: []const u8, pos: usize) bool {
        const before = pos > 0 and isWordChar(s[pos - 1]);
        const after = pos < s.len and isWordChar(s[pos]);
        return before != after;
    }

    fn addThread(prog: []const Inst, list: *std.ArrayList(u32), seen: []bool, pcv: u32, s: []const u8, pos: usize, a: std.mem.Allocator) error{OutOfMemory}!void {
        if (seen[pcv]) return;
        seen[pcv] = true;
        switch (prog[pcv]) {
            .jmp => |t| try addThread(prog, list, seen, t, s, pos, a),
            .split => |ts| {
                try addThread(prog, list, seen, ts[0], s, pos, a);
                try addThread(prog, list, seen, ts[1], s, pos, a);
            },
            .assert_start => if (pos == 0) try addThread(prog, list, seen, pcv + 1, s, pos, a),
            .assert_end => if (pos == s.len) try addThread(prog, list, seen, pcv + 1, s, pos, a),
            .assert_wordb => if (wordBoundary(s, pos)) try addThread(prog, list, seen, pcv + 1, s, pos, a),
            .assert_nwordb => if (!wordBoundary(s, pos)) try addThread(prog, list, seen, pcv + 1, s, pos, a),
            else => try list.append(a, pcv),
        }
    }
};

/// Exposed for check_test.zig — full-match a value against a `/…/` literal.
pub fn regexFullMatch(a: std.mem.Allocator, regex_literal: []const u8, s: []const u8) error{OutOfMemory}!?bool {
    var body = regex_literal;
    if (body.len >= 2 and body[0] == '/' and body[body.len - 1] == '/') {
        body = body[1 .. body.len - 1];
    }
    return Rx.fullMatch(a, body, s) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadRegex => return null,
    };
}

// --------------------------------------------------------------------------- #
// Value-prop helpers (check.py `_grant_ref_parts`, `_ref_dotted`, `_lit_str`,
// `_string_lit`, `_string_list_values`)
// --------------------------------------------------------------------------- #

const DomGrant = struct { dom: []const u8, grant: []const u8 };

/// check.py `_grant_ref_parts` — a bare `domain.grant` ref (no args/record).
fn grantRefParts(v: parser.Expr) ?DomGrant {
    switch (v) {
        .app => |ap| {
            if (ap.args == null and ap.record == null and ap.ref.parts.len == 2)
                return .{ .dom = ap.ref.parts[0], .grant = ap.ref.parts[1] };
            return null;
        },
        else => return null,
    }
}

/// check.py `_ref_dotted` — a bare ref (any arity), as the parsed Ref.
fn bareRef(v: parser.Expr) ?parser.Ref {
    switch (v) {
        .app => |ap| {
            if (ap.args == null and ap.record == null) return ap.ref;
            return null;
        },
        else => return null,
    }
}

/// check.py `_lit_str` / `_string_lit` — the value of a string literal.
fn litStr(v: ?parser.Expr) ?[]const u8 {
    const e = v orelse return null;
    switch (e) {
        .literal => |l| return if (l.kind == .string) l.value else null,
        else => return null,
    }
}

fn refSpan4(r: parser.Ref) Span4 {
    return .{ .bs = r.byte_start, .be = r.byte_end, .line = r.line, .col = r.col };
}

// --------------------------------------------------------------------------- #
// Closed-world reference resolution helpers (check.py #7 — 0011 §6.1 stage 2)
// --------------------------------------------------------------------------- #

pub const KindName = struct { kind: []const u8, name: []const u8 };

fn containsKindName(list: []const KindName, kind: []const u8, name: []const u8) bool {
    for (list) |kn| {
        if (std.mem.eql(u8, kn.kind, kind) and std.mem.eql(u8, kn.name, name)) return true;
    }
    return false;
}

fn containsDeclName(list: []const KindName, name: []const u8) bool {
    for (list) |kn| if (std.mem.eql(u8, kn.name, name)) return true;
    return false;
}

/// check.py `_collect_runtime_decls` — every (kind, name) declared anywhere
/// within the runtime subtree (P.Decl children only, recursively).
fn collectRuntimeDecls(a: std.mem.Allocator, decl: *const parser.Decl, out: *std.ArrayList(KindName)) error{OutOfMemory}!void {
    for (decl.body) |st| switch (st) {
        .decl => |d| {
            try out.append(a, .{ .kind = d.kind, .name = d.name });
            try collectRuntimeDecls(a, d, out);
        },
        else => {},
    };
}

/// check.py `_ref_fields()` — `_DEPENDS_FIELDS` ∪ {fibers, budget, runclass}.
fn isRefField(name: []const u8) bool {
    const fields = [_][]const u8{ "input", "output", "from", "source", "engine", "fibers", "budget", "runclass" };
    for (fields) |f| if (std.mem.eql(u8, f, name)) return true;
    return false;
}

/// check.py `_TOPOLOGY_DEFERRED_KINDS` — trust/quorum/probe subtrees are
/// skipped by the depends-ref walk ONLY (conformance recursion still runs).
fn isTopologyDeferred(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "trust") or std.mem.eql(u8, kind, "quorum") or
        std.mem.eql(u8, kind, "probe");
}

const RefHit = struct { ref: parser.Ref, field: []const u8, owner: *const parser.Decl };

/// check.py `_refs_in_value` — the bare-ref dependency targets of a value:
/// the value itself when it is a bare ref-app, or the bare ref-app elements
/// of a list literal. Calls / config blocks / nested refs are NOT targets.
fn appendBareRefs(a: std.mem.Allocator, v: parser.Expr, field: []const u8, owner: *const parser.Decl, out: *std.ArrayList(RefHit)) error{OutOfMemory}!void {
    if (bareRef(v)) |r| {
        try out.append(a, .{ .ref = r, .field = field, .owner = owner });
        return;
    }
    switch (v) {
        .list => |items| for (items) |x| {
            if (bareRef(x)) |r| try out.append(a, .{ .ref = r, .field = field, .owner = owner });
        },
        else => {},
    }
}

/// check.py `_walk_depends_refs` — every bare ref appearing in a ref-bearing
/// field within the decl subtree (topology-deferred kinds skipped).
fn walkDependsRefs(a: std.mem.Allocator, decl: *const parser.Decl, out: *std.ArrayList(RefHit)) error{OutOfMemory}!void {
    for (decl.body) |st| switch (st) {
        .assign => |asn| if (isRefField(asn.target)) {
            try appendBareRefs(a, asn.value.*, asn.target, decl, out);
        },
        .decl => |d| if (!isTopologyDeferred(d.kind)) try walkDependsRefs(a, d, out),
        else => {},
    };
}

/// check.py `_ACCESSOR_REFS` — (head, accessor-field) -> the kind the middle
/// segment must name.
fn accessorKind(head: []const u8, field: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, head, "secret") and std.mem.eql(u8, field, "path")) return "secret";
    if (std.mem.eql(u8, head, "hostResource") and std.mem.eql(u8, field, "dsn")) return "hostResource";
    return null;
}

/// check.py `_walk_accessor_refs` — every 3-part accessor ref anywhere in the
/// decl subtree, incl. inside config-block records and value lists.
fn walkAccessorRefs(a: std.mem.Allocator, decl: *const parser.Decl, out: *std.ArrayList(parser.Ref)) error{OutOfMemory}!void {
    for (decl.body) |st| switch (st) {
        .assign => |asn| try scanAccessorValue(a, asn.value.*, out),
        .app => |ap| try scanAccessorApp(a, ap, out),
        .decl => |d| try walkAccessorRefs(a, d, out),
        else => {},
    };
}

fn scanAccessorValue(a: std.mem.Allocator, v: parser.Expr, out: *std.ArrayList(parser.Ref)) error{OutOfMemory}!void {
    switch (v) {
        .app => |ap| try scanAccessorApp(a, ap, out),
        .list => |items| for (items) |x| try scanAccessorValue(a, x, out),
        .record => |entries| for (entries) |e| switch (e) {
            .assign => |asn| try scanAccessorValue(a, asn.value.*, out),
            else => {},
        },
        .literal => {},
    }
}

fn scanAccessorApp(a: std.mem.Allocator, ap: parser.App, out: *std.ArrayList(parser.Ref)) error{OutOfMemory}!void {
    if (ap.args == null and ap.record == null and ap.ref.parts.len == 3) {
        try out.append(a, ap.ref);
    }
    if (ap.record) |rec| for (rec) |e| switch (e) {
        .assign => |asn| try scanAccessorValue(a, asn.value.*, out),
        else => {},
    };
    if (ap.args) |args| for (args) |arg| try scanAccessorValue(a, arg, out);
}

/// check.py `_collect_runtime_namespaces` — `namespace` blocks declared
/// DIRECTLY inside the runtime (decision D3, RFC 0017). Last head wins.
const LocalNs = struct { head: []const u8, open: bool, members: []const []const u8 };

fn collectRuntimeNamespaces(a: std.mem.Allocator, runtime: *const parser.Decl) error{OutOfMemory}![]const LocalNs {
    var out: std.ArrayList(LocalNs) = .empty;
    for (runtime.body) |st| switch (st) {
        .decl => |d| if (std.mem.eql(u8, d.kind, "namespace")) {
            var is_open = false;
            var members: std.ArrayList([]const u8) = .empty;
            for (d.body) |x| switch (x) {
                .open => is_open = true,
                .member => |m| if (!containsString(members.items, m.name)) try members.append(a, m.name),
                else => {},
            };
            const spec = LocalNs{ .head = d.name, .open = is_open, .members = try members.toOwnedSlice(a) };
            var replaced = false;
            for (out.items) |*existing| {
                if (std.mem.eql(u8, existing.head, d.name)) {
                    existing.* = spec; // dict semantics: last wins
                    replaced = true;
                    break;
                }
            }
            if (!replaced) try out.append(a, spec);
        },
        else => {},
    };
    return out.toOwnedSlice(a);
}

// --------------------------------------------------------------------------- #
// `use`-import path resolution (check.py `_collect_import_decls`) — posix
// os.path.join / os.path.normpath equivalents, exact enough that the same
// files open (the strings are never printed).
// --------------------------------------------------------------------------- #

fn joinPath(a: std.mem.Allocator, base: []const u8, p: []const u8) error{OutOfMemory}![]const u8 {
    if (p.len > 0 and p[0] == '/') return p;
    if (base.len == 0) return p;
    if (base[base.len - 1] == '/') return std.fmt.allocPrint(a, "{s}{s}", .{ base, p });
    return std.fmt.allocPrint(a, "{s}/{s}", .{ base, p });
}

fn normPath(a: std.mem.Allocator, p: []const u8) error{OutOfMemory}![]const u8 {
    if (p.len == 0) return ".";
    const is_abs = p[0] == '/';
    var comps: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |comp| {
        if (comp.len == 0 or std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            if (comps.items.len > 0 and !std.mem.eql(u8, comps.items[comps.items.len - 1], "..")) {
                _ = comps.pop();
            } else if (!is_abs) {
                try comps.append(a, comp);
            }
            continue;
        }
        try comps.append(a, comp);
    }
    if (comps.items.len == 0) return if (is_abs) "/" else ".";
    const joined = try std.mem.join(a, "/", comps.items);
    if (is_abs) return std.fmt.allocPrint(a, "/{s}", .{joined});
    return joined;
}

// --------------------------------------------------------------------------- #
// Network-egress host classification (check.py `_required_egress_grant`) —
// Python `ipaddress.ip_address` semantics for loopback/private detection.
// --------------------------------------------------------------------------- #

fn parseIpv4(h: []const u8) ?[4]u8 {
    var octets: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, h, '.');
    var i: usize = 0;
    while (it.next()) |part| {
        if (i >= 4) return null;
        if (part.len == 0 or part.len > 3) return null;
        // Python 3.9+: leading zeros are rejected ("010" is not an address)
        if (part.len > 1 and part[0] == '0') return null;
        var v: u32 = 0;
        for (part) |c| {
            if (c < '0' or c > '9') return null;
            v = v * 10 + (c - '0');
        }
        if (v > 255) return null;
        octets[i] = @intCast(v);
        i += 1;
    }
    if (i != 4) return null;
    return octets;
}

/// The IPv4 is_private networks of Python `ipaddress` (loopback 127/8 is
/// handled by the caller first, exactly like check.py).
fn isPrivateV4(ip: [4]u8) bool {
    if (ip[0] == 0) return true; // 0.0.0.0/8
    if (ip[0] == 10) return true; // 10.0.0.0/8
    if (ip[0] == 127) return true; // 127.0.0.0/8 (caller catches first)
    if (ip[0] == 169 and ip[1] == 254) return true; // 169.254.0.0/16
    if (ip[0] == 172 and ip[1] >= 16 and ip[1] <= 31) return true; // 172.16.0.0/12
    if (ip[0] == 192 and ip[1] == 0 and ip[2] == 0) return true; // 192.0.0.0/24
    if (ip[0] == 192 and ip[1] == 0 and ip[2] == 2) return true; // 192.0.2.0/24
    if (ip[0] == 192 and ip[1] == 168) return true; // 192.168.0.0/16
    if (ip[0] == 198 and (ip[1] == 18 or ip[1] == 19)) return true; // 198.18.0.0/15
    if (ip[0] == 198 and ip[1] == 51 and ip[2] == 100) return true; // 198.51.100.0/24
    if (ip[0] == 203 and ip[1] == 0 and ip[2] == 113) return true; // 203.0.113.0/24
    if (ip[0] >= 240) return true; // 240.0.0.0/4 (incl. 255.255.255.255)
    return false;
}

/// Minimal IPv6 parse to 16 bytes: hex groups + one `::`. Zone ids, embedded
/// IPv4 tails, and other exotica return null (the caller then classifies the
/// host as `egress`, the same conservative bucket Python puts DNS names in).
fn parseIpv6(h: []const u8) ?[16]u8 {
    var groups: [8]u16 = undefined;
    var head_n: usize = 0;
    var tail: [8]u16 = undefined;
    var tail_n: usize = 0;
    var seen_dc = false;
    var i: usize = 0;
    const n = h.len;
    if (n < 2) return null;
    if (std.mem.startsWith(u8, h, "::")) {
        seen_dc = true;
        i = 2;
    }
    while (i < n) {
        var j = i;
        var v: u32 = 0;
        var digits: usize = 0;
        while (j < n and h[j] != ':') : (j += 1) {
            const c = h[j];
            const d: u32 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return null,
            };
            v = v * 16 + d;
            digits += 1;
            if (digits > 4) return null;
        }
        if (digits == 0) return null;
        if (seen_dc) {
            if (tail_n >= 8) return null;
            tail[tail_n] = @intCast(v);
            tail_n += 1;
        } else {
            if (head_n >= 8) return null;
            groups[head_n] = @intCast(v);
            head_n += 1;
        }
        if (j == n) break;
        // h[j] == ':'
        if (j + 1 < n and h[j + 1] == ':') {
            if (seen_dc) return null;
            seen_dc = true;
            i = j + 2;
            if (i == n) break;
        } else {
            if (j + 1 == n) return null; // trailing single ':'
            i = j + 1;
        }
    }
    var full: [8]u16 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
    if (seen_dc) {
        if (head_n + tail_n > 7) return null;
        for (0..head_n) |k| full[k] = groups[k];
        for (0..tail_n) |k| full[8 - tail_n + k] = tail[k];
    } else {
        if (head_n != 8) return null;
        full = groups[0..8].*;
    }
    var bytes: [16]u8 = undefined;
    for (full, 0..) |g, k| {
        bytes[k * 2] = @intCast(g >> 8);
        bytes[k * 2 + 1] = @intCast(g & 0xff);
    }
    return bytes;
}

/// check.py `_required_egress_grant` — loopback < lan < egress.
fn requiredEgressGrant(host: []const u8) []const u8 {
    const h = std.mem.trim(u8, host, " \t\n\r\x0b\x0c");
    if (std.mem.eql(u8, h, "localhost")) return "loopback";
    if (parseIpv4(h)) |ip| {
        if (ip[0] == 127) return "loopback";
        if (isPrivateV4(ip)) return "lan";
        return "egress";
    }
    if (std.mem.indexOfScalar(u8, h, ':') != null) {
        if (parseIpv6(h)) |b| {
            var all_zero = true;
            for (b[0..15]) |x| {
                if (x != 0) {
                    all_zero = false;
                    break;
                }
            }
            if (all_zero and (b[15] == 0 or b[15] == 1)) return if (b[15] == 1) "loopback" else "lan"; // ::1 / ::
            if (b[0] & 0xfe == 0xfc) return "lan"; // fc00::/7 unique-local
            if (b[0] == 0xfe and b[1] & 0xc0 == 0x80) return "lan"; // fe80::/10 link-local
            if (b[0] == 0x20 and b[1] == 0x01 and b[2] == 0x0d and b[3] == 0xb8) return "lan"; // 2001:db8::/32
            return "egress";
        }
    }
    return "egress"; // non-loopback DNS name -> public egress (conservative)
}

// --------------------------------------------------------------------------- #
// Sibling-scope indexes (check.py `_mesh_node_index` / `_decl_kind_index`)
// --------------------------------------------------------------------------- #

const NameSet = std.StringHashMapUnmanaged(void);
const MeshIndex = std.StringArrayHashMapUnmanaged(NameSet); // mesh -> node names (last mesh wins)
const KindIndex = std.StringHashMapUnmanaged([]const u8); // decl name -> kind (last wins)
const NetworkIndex = std.StringArrayHashMapUnmanaged(*const parser.Decl); // network decls (last wins)

fn indexSiblingDecl(a: std.mem.Allocator, d: *const parser.Decl, meshes: *MeshIndex, kinds: *KindIndex, networks: *NetworkIndex) error{OutOfMemory}!void {
    if (std.mem.eql(u8, d.kind, "mesh")) {
        var names: NameSet = .empty;
        for (d.body) |st| switch (st) {
            .node => |n| try names.put(a, n.name, {}),
            else => {},
        };
        try meshes.put(a, d.name, names);
    }
    try kinds.put(a, d.name, d.kind);
    if (std.mem.eql(u8, d.kind, "network")) {
        try networks.put(a, d.name, d);
    }
}

// --------------------------------------------------------------------------- #
// The checker
// --------------------------------------------------------------------------- #

/// Kinds whose conformance schema is named differently from the kind
/// (check.py `_KIND_SCHEMA`).
fn kindSchemaName(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "network")) return "networkMembrane";
    return kind;
}

/// by_name_kind entry — (kind, name) of a TOP-LEVEL decl (check.py builds a
/// dict keyed on the pair; get() is last-wins, key iteration first-insertion).
const NamedDecl = struct { kind: []const u8, name: []const u8, decl: *const parser.Decl };

fn byNameKindGet(list: []const NamedDecl, kind: []const u8, name: []const u8) ?*const parser.Decl {
    var i = list.len;
    while (i > 0) {
        i -= 1; // dict value semantics: the LAST decl bound to the key
        if (std.mem.eql(u8, list[i].kind, kind) and std.mem.eql(u8, list[i].name, name)) return list[i].decl;
    }
    return null;
}

/// check.py `_resolve_kind` — the kind of the in-file decl a dotted ref names.
fn resolveKindOf(list: []const NamedDecl, parts: []const []const u8) ?[]const u8 {
    if (parts.len == 2 and parser.isKind(parts[0])) {
        if (byNameKindGet(list, parts[0], parts[1]) != null) return parts[0];
        return null;
    }
    if (parts.len == 1) {
        // dict key order is first-insertion; the first name match wins
        for (list) |nd| if (std.mem.eql(u8, nd.name, parts[0])) return nd.kind;
    }
    return null;
}

/// check.py `_item_schema_of` — the item-schema name a catalog/index declares
/// via `schema = schema.X`.
fn itemSchemaOf(bindings: *const Bindings) ?[]const u8 {
    const s = bindings.get("schema") orelse return null;
    const r = bareRef(s) orelse return null;
    return r.parts[r.parts.len - 1];
}

/// #224 — the side-effecting effect vocabulary (check.py `_SIDE_EFFECTS`).
fn isSideEffect(eff: []const u8) bool {
    const side = [_][]const u8{ "io", "time", "random", "network", "llm" };
    for (side) |s| if (std.mem.eql(u8, s, eff)) return true;
    return false;
}

/// #225 — eBPF hook rosters (check.py `_EBPF_OBSERVE_ONLY_HOOKS` /
/// `_EBPF_ENFORCE_HOOKS`).
fn isEbpfObserveOnlyHook(h: []const u8) bool {
    const hooks = [_][]const u8{ "kprobe", "kretprobe", "tracepoint", "perf" };
    for (hooks) |x| if (std.mem.eql(u8, x, h)) return true;
    return false;
}

fn isEbpfEnforceHook(h: []const u8) bool {
    const hooks = [_][]const u8{ "lsm", "cgroup_connect", "cgroup_skb", "xdp", "tc", "override_return", "send_signal" };
    for (hooks) |x| if (std.mem.eql(u8, x, h)) return true;
    return false;
}

/// Python `sorted(_EBPF_HOOKS)` rendered as a list — frozen here (the roster
/// is closed; check.py sorts the union at message-format time).
const ebpf_hooks_sorted = "['cgroup_connect', 'cgroup_skb', 'kprobe', 'kretprobe', 'lsm', 'override_return', 'perf', 'send_signal', 'tc', 'tracepoint', 'xdp']";

pub const Builtins = struct {
    items: []const parser.Item,
    src: []const u8,
    file: []const u8,
};

const Checker = struct {
    a: std.mem.Allocator,
    reg: *const Registry,
    file: []const u8,
    smap: SourceMap,
    b_file: []const u8,
    b_smap: SourceMap,
    by_name_kind: []const NamedDecl = &.{},
    diags: std.ArrayList(Diagnostic) = .empty,

    fn smapFor(self: *const Checker, f: []const u8) ?*const SourceMap {
        if (std.mem.eql(u8, f, self.file)) return &self.smap;
        if (std.mem.eql(u8, f, self.b_file)) return &self.b_smap;
        return null;
    }

    fn emit(self: *Checker, code: []const u8, file: []const u8, span: Span4, decl_label: []const u8, message: []const u8) error{OutOfMemory}!void {
        try self.emitSev(code, file, span, decl_label, message, .@"error");
    }

    fn emitSev(self: *Checker, code: []const u8, file: []const u8, span: Span4, decl_label: []const u8, message: []const u8, severity: diagnostic.Severity) error{OutOfMemory}!void {
        try self.diags.append(self.a, .{
            .code = code,
            .message = message,
            .file = file,
            .line = span.line,
            .col = span.col,
            .byte_start = span.bs,
            .byte_end = span.be,
            .decl = decl_label,
            .severity = severity,
            .related = &.{},
        });
    }

    fn declLabel(self: *Checker, kind: []const u8, name: []const u8) error{OutOfMemory}![]const u8 {
        return std.fmt.allocPrint(self.a, "{s} {s}", .{ kind, name });
    }

    // --- load-time well-formedness (check.py §3.7 / §4.2 / §6.5) ----------

    fn checkSchemaWellformed(self: *Checker, spec: *const SchemaSpec) error{OutOfMemory}!void {
        const smap = self.smapFor(spec.origin_file);
        const dspan = spec.decl_span;
        const label = try self.declLabel("schema", spec.name);
        for (spec.fields) |f| {
            var seen_required = false;
            var seen_optional = false;
            for (f.refinements) |r| {
                const span = (if (smap) |m| m.fieldNameSpan(dspan.bs, dspan.be, f.name) else null) orelse dspan;
                switch (r) {
                    .required => seen_required = true,
                    .optional => seen_optional = true,
                    .matches => |rx| {
                        const bt = baseType(f.type_text).inner;
                        if (!std.mem.eql(u8, bt, "String") and !std.mem.eql(u8, bt, "Path")) {
                            try self.emit("E-SCHEMA-REFINEMENT", spec.origin_file, span, label, try std.fmt.allocPrint(self.a, "`matches` applies only to String or Path; field `{s}` is `{s}`", .{ f.name, f.type_text }));
                        } else if (try regexDialectError(self.a, rx)) |err| {
                            try self.emit("E-SCHEMA-BAD-REGEX", spec.origin_file, span, label, try std.fmt.allocPrint(self.a, "field `{s}`: {s}", .{ f.name, err }));
                        }
                    },
                    .oneof => |items| {
                        if (items.len < 1) {
                            try self.emit("E-SCHEMA-REFINEMENT", spec.origin_file, span, label, try std.fmt.allocPrint(self.a, "field `{s}`: `oneof` needs at least one element", .{f.name}));
                        }
                        for (items) |it| {
                            const ok = switch (it) {
                                .literal => |l| literalMatchesType(l.kind, l.value, f.type_text),
                                else => false,
                            };
                            if (!ok) {
                                const rendered = switch (it) {
                                    .literal => |l| try renderLiteral(self.a, l),
                                    else => try renderValue(self.a, it),
                                };
                                try self.emit("E-SCHEMA-BAD-ONEOF", spec.origin_file, span, label, try std.fmt.allocPrint(self.a, "field `{s}`: `oneof` element {s} does not match type `{s}`", .{ f.name, rendered, f.type_text }));
                            }
                        }
                    },
                    .cmp => {
                        if (!isNumericType(f.type_text)) {
                            try self.emit("E-SCHEMA-REFINEMENT", spec.origin_file, span, label, try std.fmt.allocPrint(self.a, "field `{s}`: numeric refinement on non-numeric type `{s}`", .{ f.name, f.type_text }));
                        }
                    },
                    .range => |rg| {
                        if (!isNumericType(f.type_text)) {
                            try self.emit("E-SCHEMA-REFINEMENT", spec.origin_file, span, label, try std.fmt.allocPrint(self.a, "field `{s}`: numeric refinement on non-numeric type `{s}`", .{ f.name, f.type_text }));
                        }
                        const lo = num(rg.lo);
                        const hi = num(rg.hi);
                        if (lo != null and hi != null and lo.? > hi.?) {
                            try self.emit("E-SCHEMA-BAD-RANGE", spec.origin_file, span, label, try std.fmt.allocPrint(self.a, "field `{s}`: range lower bound {s} exceeds upper bound {s}", .{ f.name, rg.lo, rg.hi }));
                        }
                    },
                    .default => |e| {
                        // default must satisfy the field type; no refs allowed.
                        switch (e.*) {
                            .app => try self.emit("E-SCHEMA-BAD-DEFAULT", spec.origin_file, span, label, try std.fmt.allocPrint(self.a, "field `{s}`: `default` must be a literal, not a ref", .{f.name})),
                            .literal => |l| if (!literalMatchesType(l.kind, l.value, f.type_text)) {
                                try self.emit("E-SCHEMA-BAD-DEFAULT", spec.origin_file, span, label, try std.fmt.allocPrint(self.a, "field `{s}`: default {s} does not match type `{s}`", .{ f.name, try renderLiteral(self.a, l), f.type_text }));
                            },
                            else => {},
                        }
                    },
                    else => {},
                }
            }
            if (seen_required and (seen_optional or f.has_default)) {
                const span = (if (smap) |m| m.fieldNameSpan(dspan.bs, dspan.be, f.name) else null) orelse dspan;
                try self.emit("E-SCHEMA-REFINEMENT", spec.origin_file, span, label, try std.fmt.allocPrint(self.a, "field `{s}`: `required` cannot be combined with `optional`/`default`", .{f.name}));
            }
        }
    }

    fn checkCapabilityWellformed(self: *Checker, spec: *CapabilitySpec) error{OutOfMemory}!void {
        const smap = self.smapFor(spec.origin_file);
        const dspan = spec.decl_span;
        const label = try self.declLabel("capability", spec.domain);
        // 1. every grant named in order must be declared
        var named: std.ArrayList([]const u8) = .empty;
        for (spec.order_chains) |ch| for (ch) |g| {
            if (!containsString(named.items, g)) try named.append(self.a, g);
        };
        var dangling: std.ArrayList([]const u8) = .empty;
        for (named.items) |g| {
            if (!containsString(spec.grants, g)) try dangling.append(self.a, g);
        }
        std.sort.insertion([]const u8, dangling.items, {}, strLess);
        for (dangling.items) |g| {
            const gs = (if (smap) |m| m.fieldNameSpan(dspan.bs, dspan.be, g) else null) orelse dspan;
            try self.emit("E-CAP-ORDER-DANGLING", spec.origin_file, gs, label, try std.fmt.allocPrint(self.a, "capability `{s}`: order names grant `{s}` which is not declared by a `grant` statement", .{ spec.domain, g }));
        }
        // 2/3. acyclicity (antisymmetry) of the closure; the closure is kept
        // on the spec for every later capability check (check.py sets
        // spec.leq the same way).
        const closure = try computeClosure(self.a, spec.grants, spec.order_chains);
        if (closure.cycle) |cyc| {
            try self.emit("E-CAP-ORDER-CYCLE", spec.origin_file, dspan, label, try std.fmt.allocPrint(self.a, "capability `{s}`: order is cyclic (`{s}` and `{s}` are mutually ≤) — the relation must be a partial order", .{ spec.domain, cyc[0], cyc[1] }));
            spec.leq = try identityLeq(self.a, spec.grants);
        } else {
            spec.leq = closure.leq;
        }
    }

    fn checkNamespaceWellformed(self: *Checker, spec: *const NamespaceSpec) error{OutOfMemory}!void {
        if (spec.open and spec.members.len > 0) {
            const label = try self.declLabel("namespace", spec.head);
            try self.emit("E-SCHEMA-REFINEMENT", spec.origin_file, spec.decl_span, label, try std.fmt.allocPrint(self.a, "namespace `{s}`: body mixes `open` with `member` declarations; use `open` alone (any member) or `member <name>` alone (closed set)", .{spec.head}));
        }
    }

    // --- constraints (§3) --------------------------------------------------

    fn isEmptyValue(v: parser.Expr) bool {
        return switch (v) {
            .list => |items| items.len == 0,
            .literal => |l| l.kind == .null or l.value.len == 0,
            else => false,
        };
    }

    fn litInOneof(l: parser.Literal, items: []const parser.Expr) bool {
        for (items) |it| switch (it) {
            .literal => |al| {
                if (al.kind == l.kind and std.mem.eql(u8, al.value, l.value)) return true;
                // numeric tolerance: Int literal vs Int oneof element (and the
                // Python both-unparseable None == None edge)
                if (al.kind == .number and l.kind == .number) {
                    const x = num(al.value);
                    const y = num(l.value);
                    if (x == null and y == null) return true;
                    if (x != null and y != null and x.? == y.?) return true;
                }
            },
            else => {},
        };
        return false;
    }

    fn renderOneof(self: *Checker, items: []const parser.Expr) error{OutOfMemory}![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.append(self.a, '[');
        var first = true;
        for (items) |it| switch (it) {
            .literal => |l| {
                if (!first) try out.appendSlice(self.a, ", ");
                first = false;
                try out.appendSlice(self.a, try renderLiteral(self.a, l));
            },
            else => {},
        };
        try out.append(self.a, ']');
        return out.toOwnedSlice(self.a);
    }

    fn valueNumber(v: parser.Expr) ?f64 {
        return switch (v) {
            .literal => |l| if (l.kind == .number) num(l.value) else null,
            else => null,
        };
    }

    fn checkFieldConstraints(self: *Checker, v: parser.Expr, f: *const FieldSpec, decl_label: []const u8, smap: ?*const SourceMap, file: []const u8, decl_span: Span4) error{OutOfMemory}!void {
        const vspan = (if (smap) |m| m.fieldValueSpan(decl_span.bs, decl_span.be, f.name) else null) orelse decl_span;
        for (f.refinements) |r| switch (r) {
            .nonempty => if (isEmptyValue(v)) {
                try self.emit("E-CONSTRAINT-NONEMPTY", file, vspan, decl_label, try std.fmt.allocPrint(self.a, "field `{s}` is `nonempty` but the value is empty", .{f.name}));
            },
            .oneof => |items| switch (v) {
                .literal => |l| if (!litInOneof(l, items)) {
                    try self.emit("E-CONSTRAINT-ONEOF", file, vspan, decl_label, try std.fmt.allocPrint(self.a, "field `{s}`: value {s} is not one of {s}", .{ f.name, try renderValue(self.a, v), try self.renderOneof(items) }));
                },
                else => {},
            },
            .cmp => |c| {
                const vn = valueNumber(v) orelse continue;
                const b = num(c.num) orelse continue;
                const ok = if (std.mem.eql(u8, c.op, ">=")) vn >= b else if (std.mem.eql(u8, c.op, "<=")) vn <= b else if (std.mem.eql(u8, c.op, ">")) vn > b else if (std.mem.eql(u8, c.op, "<")) vn < b else true;
                if (!ok) {
                    try self.emit("E-CONSTRAINT-RANGE", file, vspan, decl_label, try std.fmt.allocPrint(self.a, "field `{s}`: value {s} violates `{s} {s}`", .{ f.name, try fmtNum(self.a, vn), c.op, c.num }));
                }
            },
            .range => |rg| {
                const vn = valueNumber(v) orelse continue;
                const lo = num(rg.lo) orelse continue;
                const hi = num(rg.hi) orelse continue;
                if (!(lo <= vn and vn <= hi)) {
                    try self.emit("E-CONSTRAINT-RANGE", file, vspan, decl_label, try std.fmt.allocPrint(self.a, "field `{s}`: value {s} is outside `in {s} .. {s}`", .{ f.name, try fmtNum(self.a, vn), rg.lo, rg.hi }));
                }
            },
            // required/optional/default/matches handled in conformance / load-time
            else => {},
        };
    }

    /// check.py `_check_matches` — apply `matches /re/` to a String/Path value.
    fn checkMatches(self: *Checker, v: parser.Expr, regex_literal: []const u8, f: *const FieldSpec, decl_label: []const u8, file: []const u8, vspan: Span4) error{OutOfMemory}!void {
        const l = switch (v) {
            .literal => |l| l,
            else => return, // only literal String/Path values are matchable
        };
        if (l.kind != .string and l.kind != .path) return;
        var body = regex_literal;
        if (body.len >= 2 and body[0] == '/' and body[body.len - 1] == '/') {
            body = body[1 .. body.len - 1];
        }
        const matched = Rx.fullMatch(self.a, body, l.value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // malformed regex already reported at load as E-SCHEMA-BAD-REGEX
            error.BadRegex => return,
        };
        if (!matched) {
            try self.emit("E-CONSTRAINT-MATCHES", file, vspan, decl_label, try std.fmt.allocPrint(self.a, "field `{s}`: value {s} does not match /{s}/", .{ f.name, try renderValue(self.a, v), body }));
        }
    }

    // --- conformance (§1.1) -------------------------------------------------

    fn conformDecl(self: *Checker, decl: *const parser.Decl, schema: *const SchemaSpec) error{OutOfMemory}!void {
        const dspan = declSpan4(decl);
        const label = try self.declLabel(decl.kind, decl.name);
        var bindings = try declFieldBindings(self.a, decl.body);

        // Clause 1 — required fields present.
        for (schema.fields) |f| {
            if (f.presence == .required and bindings.get(f.name) == null) {
                try self.emit("E-CONFORM-MISSING-FIELD", self.file, dspan, label, try std.fmt.allocPrint(self.a, "required field `{s}` of schema `{s}` is missing", .{ f.name, schema.name }));
            }
        }

        // Clause 5 — unknown fields (closed schemas only).
        if (!schema.open) {
            for (bindings.order.items) |fname| {
                if (schema.getField(fname) == null) {
                    const span = self.smap.fieldNameSpan(dspan.bs, dspan.be, fname) orelse dspan;
                    try self.emit("E-CONFORM-UNKNOWN-FIELD", self.file, span, label, try std.fmt.allocPrint(self.a, "`{s}` is not a declared field of closed schema `{s}`", .{ fname, schema.name }));
                }
            }
        }

        // Clauses 2 & 4 — field well-typedness + constraints, for bound fields.
        for (bindings.entries.items) |bound| {
            const f = schema.getField(bound.name) orelse continue;
            // nested structural sub-block (check.py `_NESTED_SCHEMA`):
            // (fiber, policy) -> fiberPolicy
            if (std.mem.eql(u8, decl.kind, "fiber") and std.mem.eql(u8, bound.name, "policy")) {
                if (self.reg.getSchema("fiberPolicy")) |nested| {
                    const rec: ?[]const parser.RecordEntry = switch (bound.value) {
                        .record => |entries| entries,
                        .app => |ap| ap.record,
                        else => null,
                    };
                    if (rec) |entries| {
                        try self.conformNestedRecord(entries, nested, label, bound.name, dspan);
                        continue;
                    }
                }
            }
            if (!try valueMatchesType(self.a, self.reg, bound.value, f.type_text)) {
                const span = self.smap.fieldValueSpan(dspan.bs, dspan.be, bound.name) orelse dspan;
                try self.emit("E-CONFORM-TYPE", self.file, span, label, try std.fmt.allocPrint(self.a, "field `{s}` of schema `{s}` expects `{s}` but got {s}", .{ bound.name, schema.name, f.type_text, try renderValue(self.a, bound.value) }));
            }
            try self.checkFieldConstraints(bound.value, f, label, &self.smap, self.file, dspan);
            // matches (regex) — applies to scalar string/path values.
            // 0011 §3.5: a pattern the dialect validator rejected was already
            // reported at load (E-SCHEMA-BAD-REGEX); the matches-constraint
            // is undefined on it — skip, exactly like check.py.
            for (f.refinements) |r| switch (r) {
                .matches => |rx| {
                    if (try regexDialectError(self.a, rx) != null) continue;
                    const vspan = self.smap.fieldValueSpan(dspan.bs, dspan.be, bound.name) orelse dspan;
                    try self.checkMatches(bound.value, rx, f, label, self.file, vspan);
                },
                else => {},
            };
        }
    }

    fn conformNestedRecord(self: *Checker, entries: []const parser.RecordEntry, schema: *const SchemaSpec, owner_label: []const u8, owner_field: []const u8, decl_span: Span4) error{OutOfMemory}!void {
        var present = Bindings{};
        for (entries) |e| switch (e) {
            .assign => |asn| try present.put(self.a, asn.target, asn.value.*),
            .inherit => {},
        };
        for (schema.fields) |f| {
            if (f.presence == .required and present.get(f.name) == null) {
                try self.emit("E-CONFORM-MISSING-FIELD", self.file, decl_span, owner_label, try std.fmt.allocPrint(self.a, "required field `{s}` of nested schema `{s}` (in `{s}`) is missing", .{ f.name, schema.name, owner_field }));
            }
        }
        if (!schema.open) {
            for (present.entries.items) |e| {
                if (schema.getField(e.name) == null) {
                    const span = self.smap.fieldNameSpan(decl_span.bs, decl_span.be, e.name) orelse decl_span;
                    try self.emit("E-CONFORM-UNKNOWN-FIELD", self.file, span, owner_label, try std.fmt.allocPrint(self.a, "`{s}` is not a declared field of nested schema `{s}` (in `{s}`)", .{ e.name, schema.name, owner_field }));
                }
            }
        }
        for (present.entries.items) |e| {
            const f = schema.getField(e.name) orelse continue;
            if (!try valueMatchesType(self.a, self.reg, e.value, f.type_text)) {
                const span = self.smap.fieldValueSpan(decl_span.bs, decl_span.be, e.name) orelse decl_span;
                try self.emit("E-CONFORM-TYPE", self.file, span, owner_label, try std.fmt.allocPrint(self.a, "field `{s}` of nested schema `{s}` expects `{s}` but got {s}", .{ e.name, schema.name, f.type_text, try renderValue(self.a, e.value) }));
            }
            try self.checkFieldConstraints(e.value, f, owner_label, &self.smap, self.file, decl_span);
        }
    }

    /// check.py `_conform_node` — a mesh node / workflow step body against its
    /// structural schema. NOTE: `matches` refinements are (faithfully) NOT
    /// applied here — only `_conform_decl` runs them in Python.
    fn conformNode(self: *Checker, node: *const parser.NodeDecl, schema: *const SchemaSpec) error{OutOfMemory}!void {
        const nspan = nodeSpan4(node);
        const label = try std.fmt.allocPrint(self.a, "node {s}", .{node.name});
        var bindings = try nodeBindings(self.a, node.body);
        for (schema.fields) |f| {
            if (f.presence == .required and bindings.get(f.name) == null) {
                try self.emit("E-CONFORM-MISSING-FIELD", self.file, nspan, label, try std.fmt.allocPrint(self.a, "required field `{s}` of schema `{s}` is missing", .{ f.name, schema.name }));
            }
        }
        if (!schema.open) {
            for (bindings.order.items) |fname| {
                if (schema.getField(fname) == null) {
                    const span = self.smap.fieldNameSpan(nspan.bs, nspan.be, fname) orelse nspan;
                    try self.emit("E-CONFORM-UNKNOWN-FIELD", self.file, span, label, try std.fmt.allocPrint(self.a, "`{s}` is not a declared field of closed schema `{s}`", .{ fname, schema.name }));
                }
            }
        }
        for (bindings.entries.items) |bound| {
            const f = schema.getField(bound.name) orelse continue;
            if (!try valueMatchesType(self.a, self.reg, bound.value, f.type_text)) {
                const span = self.smap.fieldValueSpan(nspan.bs, nspan.be, bound.name) orelse nspan;
                try self.emit("E-CONFORM-TYPE", self.file, span, label, try std.fmt.allocPrint(self.a, "field `{s}` of schema `{s}` expects `{s}` but got {s}", .{ bound.name, schema.name, f.type_text, try renderValue(self.a, bound.value) }));
            }
            try self.checkFieldConstraints(bound.value, f, label, &self.smap, self.file, nspan);
        }
    }

    // --- tree walk (check.py `_check_decl_tree`) ----------------------------

    fn checkDeclTree(self: *Checker, decl: *const parser.Decl, sibling_meshes: *const MeshIndex, sibling_kinds: *const KindIndex, sibling_networks: ?*const NetworkIndex) error{OutOfMemory}!void {
        const kind = decl.kind;
        // Conformance for kinds that have a schema (skip the meta-kinds).
        if (!std.mem.eql(u8, kind, "schema") and !std.mem.eql(u8, kind, "capability")) {
            if (self.reg.getSchema(kindSchemaName(kind))) |schema| {
                try self.conformDecl(decl, schema);
            }
            try self.checkGenerics(decl);
        }
        // Mesh: node conformance + capability refs + attenuation +
        // reachability lints + network-domain POLA (check.py `_check_mesh`).
        if (std.mem.eql(u8, kind, "mesh")) {
            try self.checkMesh(decl, sibling_networks);
        }
        // Workflow (#27): step conformance, agent targets, determinism,
        // DAG/depth (check.py `_check_workflow`).
        if (std.mem.eql(u8, kind, "workflow")) {
            try self.checkWorkflow(decl, sibling_meshes, sibling_kinds);
        }
        // eBPF (#225): hook/intent typing (check.py `_check_ebpf_intent`).
        if (std.mem.eql(u8, kind, "ebpf")) {
            try self.checkEbpfIntent(decl);
        }
        // Recurse into nested declarations; decls of THIS body are the
        // sibling scope (meshes/kinds/network membranes) for the children.
        var child_meshes: MeshIndex = .empty;
        var child_kinds: KindIndex = .empty;
        var child_networks: NetworkIndex = .empty;
        for (decl.body) |st| switch (st) {
            .decl => |inner| try indexSiblingDecl(self.a, inner, &child_meshes, &child_kinds, &child_networks),
            else => {},
        };
        for (decl.body) |st| switch (st) {
            .decl => |inner| try self.checkDeclTree(inner, &child_meshes, &child_kinds, &child_networks),
            else => {},
        };
    }

    // --- generics (§5, check.py `_check_generics`) --------------------------

    fn checkGenerics(self: *Checker, decl: *const parser.Decl) error{OutOfMemory}!void {
        if (!std.mem.eql(u8, decl.kind, "catalog")) return;
        const dspan = declSpan4(decl);
        const label = try self.declLabel(decl.kind, decl.name);
        var bindings = try declFieldBindings(self.a, decl.body);
        const frm = bindings.get("from") orelse return;
        const ref = bareRef(frm) orelse return;
        const dg = try ref.dotted(self.a);
        // `from` must reference an `index` (§5.1: from : Index<T>).
        if (resolveKindOf(self.by_name_kind, ref.parts)) |target_kind| {
            if (!std.mem.eql(u8, target_kind, "index")) {
                const span = self.smap.fieldValueSpan(dspan.bs, dspan.be, "from") orelse dspan;
                try self.emit("E-GENERIC-INCONSISTENT", self.file, span, label, try std.fmt.allocPrint(self.a, "catalog `from` must target an `index` (Index<T>); `{s}` is a `{s}`", .{ dg, target_kind }));
            }
        }
        // item-type agreement: catalog `schema` vs the target index `schema`.
        const cat_item = itemSchemaOf(&bindings) orelse return;
        const last = ref.parts[ref.parts.len - 1];
        const idx_decl = byNameKindGet(self.by_name_kind, "index", last) orelse return;
        var idx_bindings = try declFieldBindings(self.a, idx_decl.body);
        const idx_item = itemSchemaOf(&idx_bindings) orelse return;
        if (!std.mem.eql(u8, idx_item, cat_item)) {
            const span = self.smap.fieldValueSpan(dspan.bs, dspan.be, "from") orelse dspan;
            try self.emit("E-GENERIC-INCONSISTENT", self.file, span, label, try std.fmt.allocPrint(self.a, "catalog item type `{s}` disagrees with index `{s}` item type `{s}`", .{ cat_item, last, idx_item }));
        }
    }

    // --- capabilities (§4, check.py `_check_mesh` and friends) --------------

    const MeshNodeInfo = struct {
        node: *const parser.NodeDecl,
        grants: []const DomGrant,
        needs: []const DomGrant,
    };

    /// check.py `_check_capability_refs`. NOTE the decl label: Python passes
    /// the NodeDecl to `_emit`, and `_decl_label` has no NodeDecl arm, so the
    /// diagnostic's `decl` is the EMPTY string — bug-compatible.
    fn checkCapabilityRefs(self: *Checker, domain: []const u8, grant: []const u8, span: Span4) error{OutOfMemory}!bool {
        const cap = self.reg.getCap(domain) orelse {
            try self.emit("E-CAP-UNKNOWN-DOMAIN", self.file, span, "", try std.fmt.allocPrint(self.a, "unknown capability domain `{s}` in `{s}.{s}`", .{ domain, domain, grant }));
            return false;
        };
        if (!containsString(cap.grants, grant)) {
            try self.emit("E-CAP-UNKNOWN-GRANT", self.file, span, "", try std.fmt.allocPrint(self.a, "`{s}` is not a declared grant of capability domain `{s}`", .{ grant, domain }));
            return false;
        }
        return true;
    }

    /// `", ".join("dom.g" …)` over the grants of one domain, or null if none.
    fn joinGrantsInDom(self: *Checker, grants: []const DomGrant, dom: []const u8) error{OutOfMemory}!?[]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var any = false;
        for (grants) |g| {
            if (!std.mem.eql(u8, g.dom, dom)) continue;
            if (any) try out.appendSlice(self.a, ", ");
            try out.appendSlice(self.a, try std.fmt.allocPrint(self.a, "{s}.{s}", .{ g.dom, g.grant }));
            any = true;
        }
        if (!any) return null;
        return try out.toOwnedSlice(self.a);
    }

    fn checkMesh(self: *Checker, mesh: *const parser.Decl, sibling_networks: ?*const NetworkIndex) error{OutOfMemory}!void {
        const mesh_schema = self.reg.getSchema("meshNode");
        const mlabel = try self.declLabel(mesh.kind, mesh.name);

        // node name -> info; duplicate names keep-LAST (Python dict assign),
        // but conformance + cap-ref validation run for EVERY node statement.
        var node_map: std.StringArrayHashMapUnmanaged(MeshNodeInfo) = .empty;
        for (mesh.body) |st| switch (st) {
            .node => |n| {
                var bindings = try nodeBindings(self.a, n.body);
                const nspan = nodeSpan4(n);
                if (mesh_schema) |ms| try self.conformNode(n, ms);
                // validate + collect capability grants
                var grants: std.ArrayList(DomGrant) = .empty;
                if (bindings.get("capabilities")) |caps| switch (caps) {
                    .list => |items| for (items) |e| {
                        const dg = grantRefParts(e) orelse continue;
                        const cspan = self.smap.fieldValueSpan(n.byte_start, n.byte_end, "capabilities") orelse nspan;
                        if (try self.checkCapabilityRefs(dg.dom, dg.grant, cspan)) {
                            try grants.append(self.a, dg);
                        }
                    },
                    else => {},
                };
                // collect declared `needs` (same ref shape as capabilities)
                var needs: std.ArrayList(DomGrant) = .empty;
                if (bindings.get("needs")) |np| switch (np) {
                    .list => |items| for (items) |e| {
                        const dg = grantRefParts(e) orelse continue;
                        const nspan2 = self.smap.fieldValueSpan(n.byte_start, n.byte_end, "needs") orelse nspan;
                        if (try self.checkCapabilityRefs(dg.dom, dg.grant, nspan2)) {
                            try needs.append(self.a, dg);
                        }
                    },
                    else => {},
                };
                try node_map.put(self.a, n.name, .{
                    .node = n,
                    .grants = try grants.toOwnedSlice(self.a),
                    .needs = try needs.toOwnedSlice(self.a),
                });
            },
            else => {},
        };

        // Attenuation on delegation edges (§4.4).
        for (mesh.body) |st| switch (st) {
            .edge => |ed| {
                var i: usize = 0;
                while (i + 1 < ed.refs.len) : (i += 1) {
                    const a_ref = ed.refs[i];
                    const b_ref = ed.refs[i + 1];
                    if (a_ref.parts.len != 1 or b_ref.parts.len != 1) continue;
                    const sender = a_ref.parts[0];
                    const receiver = b_ref.parts[0];
                    const s_info = node_map.get(sender) orelse continue;
                    const r_info = node_map.get(receiver) orelse continue;
                    try self.checkEdgeAttenuation(sender, receiver, s_info.grants, r_info.grants, a_ref, b_ref, mlabel);
                }
            },
            else => {},
        };

        // Capability-reachability analysis (#226 / 0026).
        try self.checkCapabilityReachability(mesh, &node_map, mlabel);

        // Network-domain POLA (#226 / 0026).
        try self.checkEgressUse(mesh, &node_map, sibling_networks, mlabel);
    }

    /// check.py `_check_edge_attenuation` (§4.4).
    fn checkEdgeAttenuation(self: *Checker, sender: []const u8, receiver: []const u8, s_grants: []const DomGrant, r_grants: []const DomGrant, a_ref: parser.Ref, b_ref: parser.Ref, mesh_label: []const u8) error{OutOfMemory}!void {
        // span: the edge, from the sender ref start to the receiver ref end.
        const edge_span = Span4{ .bs = a_ref.byte_start, .be = b_ref.byte_end, .line = a_ref.line, .col = a_ref.col };
        for (r_grants) |rg| {
            const cap = self.reg.getCap(rg.dom) orelse continue; // unknown domain already reported
            var ok = false;
            for (s_grants) |sg| {
                if (std.mem.eql(u8, sg.dom, rg.dom) and cap.capLeq(rg.grant, sg.grant)) {
                    ok = true;
                    break;
                }
            }
            if (!ok) {
                const held = (try self.joinGrantsInDom(s_grants, rg.dom)) orelse "(none)";
                try self.emit("E-CAP-ATTENUATION", self.file, edge_span, mesh_label, try std.fmt.allocPrint(self.a, "delegation `{s} -> {s}` escalates authority: receiver holds `{s}.{s}` but sender holds {s} (receiver's grant must be ≤ the sender's in domain `{s}`)", .{ sender, receiver, rg.dom, rg.grant, held, rg.dom }));
            }
        }
    }

    /// check.py `_check_capability_reachability` — E-CAP-USE (error) +
    /// W-POLA-EXCESS / W-CONFUSED-DEPUTY (warnings).
    fn checkCapabilityReachability(self: *Checker, mesh: *const parser.Decl, node_map: *const std.StringArrayHashMapUnmanaged(MeshNodeInfo), mlabel: []const u8) error{OutOfMemory}!void {
        const names = try self.a.alloc([]const u8, node_map.count());
        @memcpy(names, node_map.keys());
        std.sort.insertion([]const u8, names, {}, strLess);

        // POLA use-check (0011 §4.3): runs BEFORE the excess loop.
        for (names) |name| {
            const info = node_map.get(name).?;
            if (info.needs.len == 0) continue; // opt-out
            const n = info.node;
            const nspan = nodeSpan4(n);
            const nvspan = self.smap.fieldValueSpan(n.byte_start, n.byte_end, "needs") orelse nspan;
            for (info.needs) |need| {
                const cap = self.reg.getCap(need.dom) orelse continue;
                var ok = false;
                for (info.grants) |g| {
                    if (std.mem.eql(u8, g.dom, need.dom) and cap.capLeq(need.grant, g.grant)) {
                        ok = true;
                        break;
                    }
                }
                if (!ok) {
                    const held_str = (try self.joinGrantsInDom(info.grants, need.dom)) orelse
                        try std.fmt.allocPrint(self.a, "(none in domain {s})", .{need.dom});
                    try self.emit("E-CAP-USE", self.file, nvspan, mlabel, try std.fmt.allocPrint(self.a, "node `{s}` uses `{s}.{s}` (declared in `needs`) but holds {s} — a held grant must dominate every exercised capability (0011 §4.3)", .{ name, need.dom, need.grant, held_str }));
                }
            }
        }

        // POLA: held grant strictly exceeds every declared need in its domain.
        for (names) |name| {
            const info = node_map.get(name).?;
            if (info.needs.len == 0) continue;
            const n = info.node;
            const nspan = nodeSpan4(n);
            const cspan = self.smap.fieldValueSpan(n.byte_start, n.byte_end, "capabilities") orelse nspan;
            for (info.grants) |g| {
                const cap = self.reg.getCap(g.dom) orelse continue;
                var have_need = false;
                var ok = false;
                var needed: std.ArrayList(u8) = .empty;
                for (info.needs) |ng| {
                    if (!std.mem.eql(u8, ng.dom, g.dom)) continue;
                    if (have_need) try needed.appendSlice(self.a, ", ");
                    try needed.appendSlice(self.a, try std.fmt.allocPrint(self.a, "{s}.{s}", .{ ng.dom, ng.grant }));
                    have_need = true;
                    if (cap.capLeq(g.grant, ng.grant)) ok = true;
                }
                if (have_need and !ok) {
                    try self.emitSev("W-POLA-EXCESS", self.file, cspan, mlabel, try std.fmt.allocPrint(self.a, "node `{s}` holds `{s}.{s}` but declares it needs only {s} — granted more authority than its declared need (least-authority violation)", .{ name, g.dom, g.grant, needed.items }), .warning);
                }
            }
        }

        // Confused deputy: a capability-holding node with ≥2 distinct callers.
        var callers_of: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
        for (mesh.body) |st| switch (st) {
            .edge => |ed| {
                var i: usize = 0;
                while (i + 1 < ed.refs.len) : (i += 1) {
                    const a_ref = ed.refs[i];
                    const b_ref = ed.refs[i + 1];
                    if (a_ref.parts.len != 1 or b_ref.parts.len != 1) continue;
                    const sender = a_ref.parts[0];
                    const receiver = b_ref.parts[0];
                    if (!node_map.contains(sender) or !node_map.contains(receiver)) continue;
                    if (std.mem.eql(u8, sender, receiver)) continue;
                    const gop = try callers_of.getOrPut(self.a, receiver);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    if (!containsString(gop.value_ptr.items, sender)) {
                        try gop.value_ptr.append(self.a, sender);
                    }
                }
            },
            else => {},
        };
        const receivers = try self.a.alloc([]const u8, callers_of.count());
        @memcpy(receivers, callers_of.keys());
        std.sort.insertion([]const u8, receivers, {}, strLess);
        for (receivers) |name| {
            const callers = callers_of.get(name).?.items;
            if (callers.len < 2) continue; // single-caller sink
            const info = node_map.get(name).?;
            if (info.grants.len == 0) continue; // holds no capability
            const nspan = nodeSpan4(info.node);
            var held: std.ArrayList(u8) = .empty;
            for (info.grants, 0..) |g, i| {
                if (i > 0) try held.appendSlice(self.a, ", ");
                try held.appendSlice(self.a, try std.fmt.allocPrint(self.a, "{s}.{s}", .{ g.dom, g.grant }));
            }
            const sorted_callers = try self.a.alloc([]const u8, callers.len);
            @memcpy(sorted_callers, callers);
            std.sort.insertion([]const u8, sorted_callers, {}, strLess);
            var caller_list: std.ArrayList(u8) = .empty;
            for (sorted_callers, 0..) |cname, i| {
                if (i > 0) try caller_list.appendSlice(self.a, ", ");
                try caller_list.appendSlice(self.a, try std.fmt.allocPrint(self.a, "`{s}`", .{cname}));
            }
            try self.emitSev("W-CONFUSED-DEPUTY", self.file, nspan, mlabel, try std.fmt.allocPrint(self.a, "node `{s}` is a shared deputy: {d} distinct callers ({s}) delegate to it while it holds {s} under its own identity (confused-deputy shape) — keep delegation inside Vaked-minted capabilities (0026 §2)", .{ name, callers.len, caller_list.items, held.items }), .warning);
        }
    }

    /// check.py `_check_egress_use` — E-EGRESS-USE + W-EGRESS-UNREFINED.
    fn checkEgressUse(self: *Checker, mesh: *const parser.Decl, node_map: *const std.StringArrayHashMapUnmanaged(MeshNodeInfo), sibling_networks: ?*const NetworkIndex, mlabel: []const u8) error{OutOfMemory}!void {
        const cap = self.reg.getCap("network") orelse return;

        var refined: NameSet = .empty;
        if (sibling_networks) |nets| {
            // sorted(network_decls) — membrane names, ascending.
            const mnames = try self.a.alloc([]const u8, nets.count());
            @memcpy(mnames, nets.keys());
            std.sort.insertion([]const u8, mnames, {}, strLess);
            for (mnames) |mname| {
                const mdecl = nets.get(mname).?;
                var bindings = try nodeBindings(self.a, mdecl.body);
                const principal = litStr(bindings.get("principal"));
                const span = declSpan4(mdecl);
                if (principal) |p| try refined.put(self.a, p, {});
                // hosts from the membrane `allow` list of egress(host, port)
                var hosts: std.ArrayList([]const u8) = .empty;
                if (bindings.get("allow")) |av| switch (av) {
                    .list => |items| for (items) |e| switch (e) {
                        .app => |ap| {
                            if (ap.ref.parts.len == 1 and std.mem.eql(u8, ap.ref.parts[0], "egress")) {
                                if (ap.args) |args| {
                                    if (args.len > 0) {
                                        if (litStr(args[0])) |h| try hosts.append(self.a, h);
                                    }
                                }
                            }
                        },
                        else => {},
                    },
                    else => {},
                };
                if (hosts.items.len == 0) continue;
                // strongest implied level (check.py `_grant_max`)
                var required: ?[]const u8 = null;
                for (hosts.items) |h| {
                    const lvl = requiredEgressGrant(h);
                    if (required == null or cap.capLeq(required.?, lvl)) required = lvl;
                }
                const principal_str = principal orelse "None"; // Python renders None
                if (principal == null or !node_map.contains(principal.?)) {
                    try self.emit("E-EGRESS-USE", self.file, span, mlabel, try std.fmt.allocPrint(self.a, "membrane `{s}` names principal `{s}` which is not a node in mesh `{s}` — a membrane cannot refine a network grant no node holds (0026)", .{ mname, principal_str, mesh.name }));
                    continue;
                }
                const info = node_map.get(principal.?).?;
                var ok = false;
                for (info.grants) |g| {
                    if (std.mem.eql(u8, g.dom, "network") and cap.capLeq(required.?, g.grant)) {
                        ok = true;
                        break;
                    }
                }
                if (!ok) {
                    var held: std.ArrayList(u8) = .empty;
                    var any = false;
                    for (info.grants) |g| {
                        if (!std.mem.eql(u8, g.dom, "network")) continue;
                        if (any) try held.appendSlice(self.a, ", ");
                        try held.appendSlice(self.a, try std.fmt.allocPrint(self.a, "network.{s}", .{g.grant}));
                        any = true;
                    }
                    const held_str: []const u8 = if (any) held.items else "no network grant";
                    try self.emit("E-EGRESS-USE", self.file, span, mlabel, try std.fmt.allocPrint(self.a, "membrane `{s}` allows egress at level `{s}` for principal `{s}` which holds {s} — a membrane cannot authorize egress beyond the principal's granted network capability (0026)", .{ mname, required.?, principal_str, held_str }));
                }
            }
        }

        // W-EGRESS-UNREFINED — unbounded egress/lan grants.
        const names = try self.a.alloc([]const u8, node_map.count());
        @memcpy(names, node_map.keys());
        std.sort.insertion([]const u8, names, {}, strLess);
        for (names) |name| {
            const info = node_map.get(name).?;
            // sorted(g for g in net grants if g in ("egress","lan"))[-1] —
            // string sort puts "egress" before "lan", so `lan` wins if held.
            var strongest: ?[]const u8 = null;
            for (info.grants) |g| {
                if (!std.mem.eql(u8, g.dom, "network")) continue;
                if (!std.mem.eql(u8, g.grant, "egress") and !std.mem.eql(u8, g.grant, "lan")) continue;
                if (strongest == null or std.mem.order(u8, strongest.?, g.grant) == .lt) strongest = g.grant;
            }
            if (strongest != null and !refined.contains(name)) {
                const n = info.node;
                const nspan = nodeSpan4(n);
                const cspan = self.smap.fieldValueSpan(n.byte_start, n.byte_end, "capabilities") orelse nspan;
                try self.emitSev("W-EGRESS-UNREFINED", self.file, cspan, mlabel, try std.fmt.allocPrint(self.a, "node `{s}` holds `network.{s}` but no networkMembrane refines it — egress is unbounded (least-authority advisory; add a `network` membrane with an `allow` set)", .{ name, strongest.? }), .warning);
            }
        }
    }

    // --- workflow (#27 / 0015, check.py `_check_workflow`) ------------------

    /// check.py `_check_step_determinism` (#224).
    fn checkStepDeterminism(self: *Checker, step: *const parser.NodeDecl, bindings: *const Bindings, wf_label: []const u8, nspan: Span4) error{OutOfMemory}!void {
        const ctrl = bindings.get("control") orelse return;
        const is_control = switch (ctrl) {
            .literal => |l| l.kind == .bool and std.mem.eql(u8, l.value, "true"),
            else => false,
        };
        if (!is_control) return;
        const effects = bindings.get("effects") orelse return;
        switch (effects) {
            .list => |items| for (items) |e| switch (e) {
                .literal => |l| if (l.kind == .string and isSideEffect(l.value)) {
                    const span = self.smap.fieldValueSpan(step.byte_start, step.byte_end, "effects") orelse nspan;
                    try self.emit("E-DETERMINISM-EFFECT", self.file, span, wf_label, try std.fmt.allocPrint(self.a, "step `{s}` is `control = true` (pure control-flow) but declares side-effecting effect `{s}`; move the side effect into a non-control step (drop `control`, or split it out)", .{ step.name, l.value }));
                    return;
                },
                else => {},
            },
            else => {},
        }
    }

    fn checkWorkflow(self: *Checker, wf: *const parser.Decl, sibling_meshes: *const MeshIndex, sibling_kinds: *const KindIndex) error{OutOfMemory}!void {
        const step_schema = self.reg.getSchema("workflowStep");
        const wlabel = try self.declLabel(wf.kind, wf.name);
        const dspan = declSpan4(wf);

        var steps: std.ArrayList([]const u8) = .empty; // declaration order
        for (wf.body) |st| switch (st) {
            .node => |n| {
                try steps.append(self.a, n.name);
                const nspan = nodeSpan4(n);
                if (step_schema) |ss| try self.conformNode(n, ss);
                var bindings = try nodeBindings(self.a, n.body);
                if (bindings.get("agent")) |av| {
                    if (grantRefParts(av)) |ag| {
                        var bad: ?[]const u8 = null;
                        if (sibling_meshes.getPtr(ag.dom)) |nodeset| {
                            if (!nodeset.contains(ag.grant)) {
                                bad = try std.fmt.allocPrint(self.a, "step `{s}`: `agent = {s}.{s}` references mesh `{s}` but it declares no node `{s}`", .{ n.name, ag.dom, ag.grant, ag.dom, ag.grant });
                            }
                        } else if (sibling_kinds.get(ag.dom)) |k| {
                            bad = try std.fmt.allocPrint(self.a, "step `{s}`: `agent = {s}.{s}` references `{s} {s}`, which is not a mesh — an agent must be a mesh node", .{ n.name, ag.dom, ag.grant, k, ag.dom });
                        }
                        if (bad) |msg| {
                            const span = self.smap.fieldValueSpan(n.byte_start, n.byte_end, "agent") orelse nspan;
                            try self.emit("E-REF-UNRESOLVED", self.file, span, wlabel, msg);
                        }
                    }
                }
                // Determinism boundary (#224).
                try self.checkStepDeterminism(n, &bindings, wlabel, nspan);
            },
            else => {},
        };

        // succ over the declared steps (duplicates in edge lists preserved).
        var succ: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
        for (steps.items) |s| {
            const gop = try succ.getOrPut(self.a, s);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
        }
        for (wf.body) |st| switch (st) {
            .edge => |ed| {
                var i: usize = 0;
                while (i + 1 < ed.refs.len) : (i += 1) {
                    const a_ref = ed.refs[i];
                    const b_ref = ed.refs[i + 1];
                    if (a_ref.parts.len != 1 or b_ref.parts.len != 1) continue;
                    const from = a_ref.parts[0];
                    const to = b_ref.parts[0];
                    if (succ.contains(from) and succ.contains(to)) {
                        try succ.getPtr(from).?.append(self.a, to);
                    }
                }
            },
            else => {},
        };

        // Cycle detection — faithful port of check.py's iterative DFS with an
        // explicit colour map (WHITE/GREY/BLACK) and persistent per-frame
        // iterators, so the REPORTED cycle path is byte-identical.
        const WHITE: u8 = 0;
        const GREY: u8 = 1;
        const BLACK: u8 = 2;
        var colour: std.StringHashMapUnmanaged(u8) = .empty;
        for (steps.items) |s| try colour.put(self.a, s, WHITE);
        var cycle: ?[]const []const u8 = null;
        const Frame = struct { node: []const u8, idx: usize };
        for (steps.items) |root| {
            if (cycle != null or colour.get(root).? != WHITE) continue;
            var stack: std.ArrayList(Frame) = .empty;
            try stack.append(self.a, .{ .node = root, .idx = 0 });
            try colour.put(self.a, root, GREY);
            var path: std.ArrayList([]const u8) = .empty;
            try path.append(self.a, root);
            while (stack.items.len > 0 and cycle == null) {
                const top = stack.items.len - 1;
                const succs = succ.get(stack.items[top].node).?.items;
                var advanced = false;
                while (stack.items[top].idx < succs.len) {
                    const nxt = succs[stack.items[top].idx];
                    stack.items[top].idx += 1;
                    const cn = colour.get(nxt).?;
                    if (cn == GREY) {
                        // cycle = path[path.index(nxt):] + [nxt]
                        var start: usize = 0;
                        for (path.items, 0..) |p, pi| {
                            if (std.mem.eql(u8, p, nxt)) {
                                start = pi;
                                break;
                            }
                        }
                        var cyc: std.ArrayList([]const u8) = .empty;
                        try cyc.appendSlice(self.a, path.items[start..]);
                        try cyc.append(self.a, nxt);
                        cycle = try cyc.toOwnedSlice(self.a);
                        break;
                    }
                    if (cn == WHITE) {
                        try colour.put(self.a, nxt, GREY);
                        try path.append(self.a, nxt);
                        try stack.append(self.a, .{ .node = nxt, .idx = 0 });
                        advanced = true;
                        break;
                    }
                    // BLACK: keep scanning this frame's successors
                }
                if (!advanced and cycle == null) {
                    try colour.put(self.a, stack.items[top].node, BLACK);
                    _ = path.pop();
                    _ = stack.pop();
                }
            }
        }
        if (cycle) |cyc| {
            const joined = try std.mem.join(self.a, " -> ", cyc);
            try self.emit("E-WORKFLOW-CYCLE", self.file, dspan, wlabel, try std.fmt.allocPrint(self.a, "workflow `{s}` step edges must form a DAG; cycle: {s} (express revision loops as `retries` on a step, not back-edges)", .{ wf.name, joined }));
            return; // depth is undefined on a cyclic graph
        }

        // Longest chain, counted in steps (memoized over the verified DAG).
        var memo: std.StringHashMapUnmanaged(usize) = .empty;
        const D = struct {
            a: std.mem.Allocator,
            succ: *const std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)),
            memo: *std.StringHashMapUnmanaged(usize),
            fn depth(d: *const @This(), s: []const u8) error{OutOfMemory}!usize {
                if (d.memo.get(s)) |v| return v;
                var best: usize = 0;
                for (d.succ.get(s).?.items) |nx| best = @max(best, try d.depth(nx));
                const v = 1 + best;
                try d.memo.put(d.a, s, v);
                return v;
            }
        };
        const dcalc = D{ .a = self.a, .succ = &succ, .memo = &memo };
        var depth: usize = 0;
        for (steps.items) |s| depth = @max(depth, try dcalc.depth(s));

        var wf_bindings = try nodeBindings(self.a, wf.body);
        const md = wf_bindings.get("maxDepth") orelse return;
        const md_lit = switch (md) {
            .literal => |l| if (l.kind == .number) l else return,
            else => return,
        };
        // Python int(str(value)); a non-integer literal is unenforceable.
        const bound = std.fmt.parseInt(i64, md_lit.value, 10) catch return;
        if (@as(i64, @intCast(depth)) > bound) {
            const span = self.smap.fieldValueSpan(dspan.bs, dspan.be, "maxDepth") orelse dspan;
            try self.emit("E-WORKFLOW-DEPTH", self.file, span, wlabel, try std.fmt.allocPrint(self.a, "workflow `{s}` has critical-path depth {d}, exceeding the declared maxDepth = {d}", .{ wf.name, depth, bound }));
        }
    }

    // --- eBPF (#225, check.py `_check_ebpf_intent`) --------------------------

    fn checkEbpfIntent(self: *Checker, decl: *const parser.Decl) error{OutOfMemory}!void {
        var bindings = try declFieldBindings(self.a, decl.body);
        const dspan = declSpan4(decl);
        const label = try self.declLabel(decl.kind, decl.name);

        const hook = litStr(bindings.get("hook"));
        const intent = litStr(bindings.get("intent"));

        if (hook) |h| {
            if (!isEbpfObserveOnlyHook(h) and !isEbpfEnforceHook(h)) {
                const span = self.smap.fieldValueSpan(dspan.bs, dspan.be, "hook") orelse dspan;
                try self.emit("E-EBPF-UNKNOWN-HOOK", self.file, span, label, try std.fmt.allocPrint(self.a, "ebpf `{s}`: unknown hook `{s}`; expected one of {s}", .{ decl.name, h, ebpf_hooks_sorted }));
                return;
            }
        }
        if (intent) |it| {
            if (!std.mem.eql(u8, it, "observe") and !std.mem.eql(u8, it, "enforce")) {
                const span = self.smap.fieldValueSpan(dspan.bs, dspan.be, "intent") orelse dspan;
                try self.emit("E-EBPF-BAD-INTENT", self.file, span, label, try std.fmt.allocPrint(self.a, "ebpf `{s}`: intent must be \"observe\" or \"enforce\", got `{s}`", .{ decl.name, it }));
                return;
            }
        }
        if (intent != null and std.mem.eql(u8, intent.?, "enforce") and hook != null and isEbpfObserveOnlyHook(hook.?)) {
            const span = self.smap.fieldValueSpan(dspan.bs, dspan.be, "hook") orelse dspan;
            try self.emit("E-EBPF-ENFORCE-ON-OBSERVE", self.file, span, label, try std.fmt.allocPrint(self.a, "ebpf `{s}` declares `intent = \"enforce\"` on observe-only hook `{s}`; {s} cannot change system behaviour. Use a verdict-capable hook (lsm, cgroup_connect/cgroup_skb, xdp/tc, override_return, send_signal) to enforce, or set `intent = \"observe\"`.", .{ decl.name, hook.?, hook.? }));
        }
    }

    // --- closed-world ref resolution (#7 — 0011 §6.1 stage 2) ---------------

    fn checkRefResolution(self: *Checker, runtime: *const parser.Decl, imported: []const KindName) error{OutOfMemory}!void {
        var declared: std.ArrayList(KindName) = .empty;
        try collectRuntimeDecls(self.a, runtime, &declared);
        try declared.appendSlice(self.a, imported);

        const runtime_ns = try collectRuntimeNamespaces(self.a, runtime);

        var refs: std.ArrayList(RefHit) = .empty;
        try walkDependsRefs(self.a, runtime, &refs);
        for (refs.items) |hit| {
            const parts = hit.ref.parts;
            const span = refSpan4(hit.ref);
            const owner_label = try self.declLabel(hit.owner.kind, hit.owner.name);
            const dotted = try hit.ref.dotted(self.a);
            if (parts.len == 2 and parser.isKind(parts[0])) {
                // `<kind>.<name>` — must name an in-runtime/imported decl.
                if (!containsKindName(declared.items, parts[0], parts[1])) {
                    try self.emit("E-REF-UNRESOLVED", self.file, span, owner_label, try std.fmt.allocPrint(self.a, "`{s}` references `{s}` but no `{s} {s}` is declared in runtime `{s}`", .{ hit.field, dotted, parts[0], parts[1], runtime.name }));
                }
            } else if (parts.len == 1) {
                // bare name — must name some in-runtime/imported decl.
                if (!containsDeclName(declared.items, parts[0])) {
                    try self.emit("E-REF-UNRESOLVED", self.file, span, owner_label, try std.fmt.allocPrint(self.a, "`{s}` references `{s}` but no declaration named `{s}` is in scope of runtime `{s}`", .{ hit.field, dotted, parts[0], runtime.name }));
                }
            } else if (parts.len >= 2) {
                // Branch B (RFC 0017, decision D2): non-kind dotted head.
                const head = parts[0];
                const member = parts[1];
                if (self.reg.cap_idx.contains(head)) continue; // capability checker owns these
                if (std.mem.eql(u8, head, "artifacts") or std.mem.eql(u8, head, "graph")) continue; // D1: deferred
                // Lookup order: runtime-scoped namespace first (D3), then the
                // global catalog.
                var ns_open: bool = undefined;
                var ns_members: []const []const u8 = undefined;
                var found = false;
                for (runtime_ns) |ns| {
                    if (std.mem.eql(u8, ns.head, head)) {
                        ns_open = ns.open;
                        ns_members = ns.members;
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    if (self.reg.getNamespace(head)) |g| {
                        ns_open = g.open;
                        ns_members = g.members;
                        found = true;
                    }
                }
                if (!found) {
                    try self.emit("E-REF-UNRESOLVED", self.file, span, owner_label, try std.fmt.allocPrint(self.a, "`{s}` references `{s}` but `{s}` is not a declared namespace in runtime `{s}` (add `namespace {s} {{ … }}` or declare it in builtins)", .{ hit.field, dotted, head, runtime.name, head }));
                } else if (!ns_open and !containsString(ns_members, member)) {
                    const sorted_members = try self.a.alloc([]const u8, ns_members.len);
                    @memcpy(sorted_members, ns_members);
                    std.sort.insertion([]const u8, sorted_members, {}, strLess);
                    try self.emit("E-REF-UNRESOLVED", self.file, span, owner_label, try std.fmt.allocPrint(self.a, "`{s}` references `{s}` but `{s}` is not a declared member of namespace `{s}` (declared members: {s})", .{ hit.field, dotted, member, head, try reprStrList(self.a, sorted_members) }));
                }
            }
        }

        // 3-part accessor refs (`secret.X.path`, `hostResource.X.dsn`).
        var accessor_refs: std.ArrayList(parser.Ref) = .empty;
        try walkAccessorRefs(self.a, runtime, &accessor_refs);
        const rt_label = try self.declLabel(runtime.kind, runtime.name);
        var seen: std.ArrayList([2]usize) = .empty;
        for (accessor_refs.items) |r| {
            const kind = accessorKind(r.parts[0], r.parts[2]) orelse continue;
            var dup = false;
            for (seen.items) |k| {
                if (k[0] == r.byte_start and k[1] == r.byte_end) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            try seen.append(self.a, .{ r.byte_start, r.byte_end });
            if (!containsKindName(declared.items, kind, r.parts[1])) {
                try self.emit("E-REF-UNRESOLVED", self.file, refSpan4(r), rt_label, try std.fmt.allocPrint(self.a, "`{s}` references `{s} {s}` but no such declaration is in scope of runtime `{s}`", .{ try r.dotted(self.a), kind, r.parts[1], runtime.name }));
            }
        }
    }
};

fn strLess(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

const Closure = struct { leq: Leq, cycle: ?[2][]const u8 };

/// check.py `_transitive_closure` — builds the reflexive-transitive ≤-closure
/// and reports the first cycle pair (per this port's deterministic iteration
/// order) when the chains are not a partial order. Python iterates hash sets
/// here, so the PAIR REPORTED on a cycle may differ from CPython run to run;
/// the code and span match. The closure matrix is kept on the spec (`leq`)
/// and reused by every capability check, exactly like check.py.
fn computeClosure(a: std.mem.Allocator, grants: []const []const u8, chains: []const []const []const u8) error{OutOfMemory}!Closure {
    var nodes: std.ArrayList([]const u8) = .empty;
    for (grants) |g| if (!containsString(nodes.items, g)) try nodes.append(a, g);
    for (chains) |ch| for (ch) |g| if (!containsString(nodes.items, g)) try nodes.append(a, g);

    const n = nodes.items.len;
    const succ = try a.alloc(std.ArrayList(usize), n);
    for (succ) |*s| s.* = .empty;
    const idxOf = struct {
        fn f(list: []const []const u8, name: []const u8) usize {
            for (list, 0..) |x, i| if (std.mem.eql(u8, x, name)) return i;
            unreachable;
        }
    }.f;
    for (chains) |ch| {
        var i: usize = 0;
        while (i + 1 < ch.len) : (i += 1) {
            const ai = idxOf(nodes.items, ch[i]);
            const bi = idxOf(nodes.items, ch[i + 1]);
            var dup = false;
            for (succ[ai].items) |x| {
                if (x == bi) {
                    dup = true;
                    break;
                }
            }
            if (!dup) try succ[ai].append(a, bi);
        }
    }
    // reach: reflexive-transitive closure via DFS
    const reach = try a.alloc([]bool, n);
    for (reach, 0..) |*row, gi| {
        row.* = try a.alloc(bool, n);
        @memset(row.*, false);
        row.*[gi] = true; // reflexive
        var stack: std.ArrayList(usize) = .empty;
        try stack.appendSlice(a, succ[gi].items);
        while (stack.pop()) |x| {
            if (!row.*[x]) {
                row.*[x] = true;
                try stack.appendSlice(a, succ[x].items);
            }
        }
    }
    const reach_const = try a.alloc([]const bool, n);
    for (reach, 0..) |row, i| reach_const[i] = row;
    const leq = Leq{ .nodes = try nodes.toOwnedSlice(a), .reach = reach_const };

    // a strict order forbids a < a (degenerate self-cycle)
    for (0..n) |gi| {
        for (succ[gi].items) |x| {
            if (x == gi) return .{ .leq = leq, .cycle = .{ leq.nodes[gi], leq.nodes[gi] } };
        }
    }
    // antisymmetry: a<=b and b<=a with a!=b ⇒ cycle
    for (0..n) |ai| {
        for (0..n) |bi| {
            if (ai != bi and reach[ai][bi] and reach[bi][ai]) {
                return .{ .leq = leq, .cycle = .{ leq.nodes[ai], leq.nodes[bi] } };
            }
        }
    }
    return .{ .leq = leq, .cycle = null };
}

/// The identity closure over the declared grants — check.py's cyclic-order
/// fallback (`spec.leq = {g: {g} for g in spec.grants}`).
fn identityLeq(a: std.mem.Allocator, grants: []const []const u8) error{OutOfMemory}!Leq {
    const n = grants.len;
    const reach = try a.alloc([]const bool, n);
    for (0..n) |i| {
        const row = try a.alloc(bool, n);
        @memset(row, false);
        row[i] = true;
        reach[i] = row;
    }
    return .{ .nodes = grants, .reach = reach };
}

// --------------------------------------------------------------------------- #
// Collision enrichment — resolve.zig detects E-DECL-NAME-COLLISION (keep-first
// addNode); this pass reshapes those diagnostics into check.py's richer form
// (check.py `_check_scope_collisions`, lines 1564-1610): keyword-token span,
// Python message wording, and a `related` pointer to the first declaration.
// Collisions Python would NOT emit (duplicate `node` names, decl-vs-node,
// children of a dropped duplicate body) are filtered out for parity.
// --------------------------------------------------------------------------- #

const CollisionInfo = struct {
    later: *const parser.Decl,
    prior: *const parser.Decl,
    top_level: bool,
};

fn collectCollisionInfos(a: std.mem.Allocator, items: []const parser.Item, out: *std.ArrayList(CollisionInfo)) error{OutOfMemory}!void {
    var decls: std.ArrayList(*const parser.Decl) = .empty;
    defer decls.deinit(a);
    for (items) |it| switch (it) {
        .decl => |d| try decls.append(a, d),
        else => {},
    };
    try collectScopeCollisions(a, decls.items, true, out);
}

fn collectScopeCollisions(a: std.mem.Allocator, siblings: []const *const parser.Decl, top_level: bool, out: *std.ArrayList(CollisionInfo)) error{OutOfMemory}!void {
    var first_seen: std.ArrayList(*const parser.Decl) = .empty;
    defer first_seen.deinit(a);
    for (siblings) |d| {
        var prior: ?*const parser.Decl = null;
        for (first_seen.items) |p| {
            if (std.mem.eql(u8, p.name, d.name)) {
                prior = p;
                break;
            }
        }
        if (prior) |p| {
            try out.append(a, .{ .later = d, .prior = p, .top_level = top_level });
        } else {
            try first_seen.append(a, d);
        }
        // Recurse into this decl's body — its own nested sibling scope.
        var child_decls: std.ArrayList(*const parser.Decl) = .empty;
        defer child_decls.deinit(a);
        for (d.body) |st| switch (st) {
            .decl => |inner| try child_decls.append(a, inner),
            else => {},
        };
        try collectScopeCollisions(a, child_decls.items, false, out);
    }
}

fn enrichCollisions(c: *Checker, resolve_diags: []const Diagnostic, infos: []const CollisionInfo) error{OutOfMemory}!void {
    for (resolve_diags) |d| {
        if (!std.mem.eql(u8, d.code, "E-DECL-NAME-COLLISION")) continue;
        // Match the resolve diagnostic to the Python-shape collision by the
        // later decl's byte range; unmatched ones (node collisions etc.) are
        // dropped — check.py does not emit them.
        //
        // TODO(check slice 2): collisions only resolve.zig detects — duplicate
        // `node` names, decl-vs-node in one body, and children of a dropped
        // duplicate body — are filtered here for check.py parity and are
        // therefore invisible to every current CLI surface. Surface them via
        // the future `parse`/`lower` subcommands, which consume resolve
        // diagnostics directly instead of the check-shaped subset.
        for (infos) |info| {
            if (info.later.byte_start != d.byte_start or info.later.byte_end != d.byte_end) continue;
            const it = info.later;
            const prior = info.prior;
            const span = c.smap.declKwSpan(it.byte_start, it.byte_end, it.kind) orelse declSpan4(it);
            const kindnote: []const u8 = if (!std.mem.eql(u8, it.kind, prior.kind)) "a different kind" else "the same kind";
            const scopenote: []const u8 = if (info.top_level) "top-level declarations" else "sibling declarations";
            const related = try c.a.alloc(diagnostic.Related, 1);
            related[0] = .{
                .file = c.file,
                .decl = try std.fmt.allocPrint(c.a, "{s} {s}", .{ prior.kind, prior.name }),
                .span = .{ .file = c.file, .byte_start = prior.byte_start, .byte_end = prior.byte_end, .line = prior.line, .col = prior.col },
                .message = try std.fmt.allocPrint(c.a, "first declared here as `{s} {s}`", .{ prior.kind, prior.name }),
            };
            try c.diags.append(c.a, .{
                .code = "E-DECL-NAME-COLLISION",
                .message = try std.fmt.allocPrint(c.a, "`{s} {s}` collides with `{s} {s}` ({s}, same name): {s} share a kind-agnostic graph id, so the later one is silently dropped — rename one", .{ it.kind, it.name, prior.kind, prior.name, kindnote, scopenote }),
                .file = c.file,
                .line = span.line,
                .col = span.col,
                .byte_start = span.bs,
                .byte_end = span.be,
                .decl = try std.fmt.allocPrint(c.a, "{s} {s}", .{ it.kind, it.name }),
                .severity = .@"error",
                .related = related,
            });
            break;
        }
    }
}

// --------------------------------------------------------------------------- #
// Sorting — check.py `Diagnostic.sort_key` = (file, byteStart, byteEnd, code),
// STABLE (Python list.sort is stable; ties keep emission order)
// --------------------------------------------------------------------------- #

pub fn diagLess(_: void, x: Diagnostic, y: Diagnostic) bool {
    const fo = std.mem.order(u8, x.file, y.file);
    if (fo != .eq) return fo == .lt;
    if (x.byte_start != y.byte_start) return x.byte_start < y.byte_start;
    if (x.byte_end != y.byte_end) return x.byte_end < y.byte_end;
    return std.mem.order(u8, x.code, y.code) == .lt;
}

// --------------------------------------------------------------------------- #
// Entry points
// --------------------------------------------------------------------------- #

pub const ParseOutcome = union(enum) {
    ok: []const parser.Item,
    fail: []const u8, // source-mapped message, no trailing newline
};

/// Lex + parse one source. Failures come back as a message (exit-2 semantics
/// live in the caller).
pub fn parseSource(a: std.mem.Allocator, src: []const u8, filename: []const u8) error{OutOfMemory}!ParseOutcome {
    var l = lex.Lexer.init(a, src);
    try l.run();
    if (l.errors.items.len > 0) {
        const le = l.errors.items[0];
        return .{ .fail = try std.fmt.allocPrint(a, "lex error in '{s}': {s} at line {d} col {d}", .{ filename, le.msg, le.line, le.col }) };
    }
    var p = parser.Parser.init(a, l.tokens.items);
    const items = p.parseFile() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Parse => {
            if (p.err) |pe| {
                return .{ .fail = try std.fmt.allocPrint(a, "parse error in '{s}': {s} at line {d} col {d}", .{ filename, pe.msg, pe.line, pe.col }) };
            }
            return .{ .fail = try std.fmt.allocPrint(a, "parse error in '{s}'", .{filename}) };
        },
    };
    return .{ .ok = items };
}

pub const CheckOutcome = union(enum) {
    ok: []Diagnostic,
    fail: []const u8,
};

/// How checkSource reads `use`-imported files (check.py opens them directly;
/// the Zig port takes the IO as a capability so the checker itself stays
/// pure/testable). `read` returns the file's bytes, or null when the path is
/// unreadable — Python's OSError path: the import is silently skipped and its
/// names simply stay unbound.
pub const ImportReader = struct {
    ctx: ?*anyopaque = null,
    read: *const fn (ctx: ?*anyopaque, a: std.mem.Allocator, path: []const u8) error{OutOfMemory}!?[]const u8,
};

const ImportsOutcome = union(enum) {
    ok: []const KindName,
    fail: []const u8,
};

/// check.py `_collect_import_decls` — resolve each `use "<path>"` (one level,
/// relative to base_dir) and collect the (kind, name) set its top-level decls
/// bind into scope. A parse failure of an imported file PROPAGATES (Python
/// raises through check_source → exit 2), unlike an unreadable file (skipped).
fn collectImportDecls(a: std.mem.Allocator, items: []const parser.Item, base_dir: []const u8, reader: ?ImportReader) error{OutOfMemory}!ImportsOutcome {
    var out: std.ArrayList(KindName) = .empty;
    const rd = reader orelse return .{ .ok = try out.toOwnedSlice(a) };
    for (items) |it| switch (it) {
        .import => |imp| {
            const path = try normPath(a, try joinPath(a, base_dir, imp.path));
            const isrc = (try rd.read(rd.ctx, a, path)) orelse continue;
            switch (try parseSource(a, isrc, path)) {
                .ok => |subitems| for (subitems) |sub| switch (sub) {
                    .decl => |d| if (!containsKindName(out.items, d.kind, d.name)) {
                        try out.append(a, .{ .kind = d.kind, .name = d.name });
                    },
                    else => {},
                },
                .fail => |msg| return .{ .fail = msg },
            }
        },
        else => {},
    };
    return .{ .ok = try out.toOwnedSlice(a) };
}

/// Check Vaked `src` against the builtins catalog and return the sorted
/// diagnostics (check.py `check_source` — full rule set). `base_dir` is the
/// directory `use` imports resolve against (Python defaults it to the file's
/// own dirname; the CLI passes exactly that); `reader` supplies the import
/// IO and may be null (no imports resolvable). Allocate from an arena that
/// outlives the result.
pub fn checkSource(a: std.mem.Allocator, src: []const u8, filename: []const u8, b: Builtins, base_dir: []const u8, reader: ?ImportReader) error{OutOfMemory}!CheckOutcome {
    const items = switch (try parseSource(a, src, filename)) {
        .ok => |items| items,
        .fail => |msg| return .{ .fail = msg },
    };

    // Stage 2 — bind `use` imports' top-level decls into this file's scope.
    const imported: []const KindName = switch (try collectImportDecls(a, items, base_dir, reader)) {
        .ok => |kns| kns,
        .fail => |msg| return .{ .fail = msg },
    };

    // Collision detection lives in resolve (keep-first addNode).
    var res = try resolve.buildGraph(a, items, filename);
    res.graph.deinit();

    // Stage 3 — elaborate: registry (built-ins first, user decls override).
    var reg = Registry{ .a = a };
    try loadDeclsInto(&reg, b.items, b.file);
    try loadDeclsInto(&reg, items, filename);

    var c = Checker{
        .a = a,
        .reg = &reg,
        .file = filename,
        .smap = try SourceMap.init(a, src),
        .b_file = b.file,
        .b_smap = try SourceMap.init(a, b.src),
    };

    // Stage 4a — load-time well-formedness of EVERY schema, capability and
    // namespace in scope, sorted by (origin_file, name) like check.py.
    {
        const specs = try a.alloc(*const SchemaSpec, reg.schemas.items.len);
        for (reg.schemas.items, 0..) |*s, i| specs[i] = s;
        std.sort.insertion(*const SchemaSpec, specs, {}, struct {
            fn less(_: void, x: *const SchemaSpec, y: *const SchemaSpec) bool {
                const fo = std.mem.order(u8, x.origin_file, y.origin_file);
                if (fo != .eq) return fo == .lt;
                return std.mem.order(u8, x.name, y.name) == .lt;
            }
        }.less);
        for (specs) |s| try c.checkSchemaWellformed(s);
    }
    {
        const specs = try a.alloc(*CapabilitySpec, reg.caps.items.len);
        for (reg.caps.items, 0..) |*s, i| specs[i] = s;
        std.sort.insertion(*CapabilitySpec, specs, {}, struct {
            fn less(_: void, x: *const CapabilitySpec, y: *const CapabilitySpec) bool {
                const fo = std.mem.order(u8, x.origin_file, y.origin_file);
                if (fo != .eq) return fo == .lt;
                return std.mem.order(u8, x.domain, y.domain) == .lt;
            }
        }.less);
        for (specs) |s| try c.checkCapabilityWellformed(s);
    }
    {
        const specs = try a.alloc(*const NamespaceSpec, reg.namespaces.items.len);
        for (reg.namespaces.items, 0..) |*s, i| specs[i] = s;
        std.sort.insertion(*const NamespaceSpec, specs, {}, struct {
            fn less(_: void, x: *const NamespaceSpec, y: *const NamespaceSpec) bool {
                const fo = std.mem.order(u8, x.origin_file, y.origin_file);
                if (fo != .eq) return fo == .lt;
                return std.mem.order(u8, x.head, y.head) == .lt;
            }
        }.less);
        for (specs) |s| try c.checkNamespaceWellformed(s);
    }

    // Index in-file TOP-LEVEL decls by (kind, name) for generics resolution.
    var by_name_kind: std.ArrayList(NamedDecl) = .empty;
    for (items) |it| switch (it) {
        .decl => |d| try by_name_kind.append(a, .{ .kind = d.kind, .name = d.name, .decl = d }),
        else => {},
    };
    c.by_name_kind = by_name_kind.items;

    // Stage 4 (pre-walk) — name collisions, enriched from resolve's output.
    var infos: std.ArrayList(CollisionInfo) = .empty;
    try collectCollisionInfos(a, items, &infos);
    try enrichCollisions(&c, res.diagnostics, infos.items);

    // Stage 4b/4c/4d — walk every in-file declaration. Top-level decls are
    // sibling scope for top-level workflows (agent-target validation, #27);
    // top-level meshes get NO network membranes (check.py passes None).
    var top_meshes: MeshIndex = .empty;
    var top_kinds: KindIndex = .empty;
    var top_networks_unused: NetworkIndex = .empty;
    for (items) |it| switch (it) {
        .decl => |d| try indexSiblingDecl(a, d, &top_meshes, &top_kinds, &top_networks_unused),
        else => {},
    };
    for (items) |it| switch (it) {
        .decl => |d| {
            try c.checkDeclTree(d, &top_meshes, &top_kinds, null);
            // Stage 2 (closed-world ref resolution) per top-level runtime.
            if (std.mem.eql(u8, d.kind, "runtime")) {
                try c.checkRefResolution(d, imported);
            }
        },
        else => {},
    };

    std.sort.insertion(Diagnostic, c.diags.items, {}, diagLess);
    return .{ .ok = try c.diags.toOwnedSlice(a) };
}

// --------------------------------------------------------------------------- #
// JSON serialization — matches vakedc's diagnostic JSON field names exactly
// (rejected.diagnostics.json golden): objects carry code/decl/file/message/
// related/severity/span in Python's sort_keys order; span objects are
// {byteEnd, byteStart, col, line} WITHOUT a file field.
// --------------------------------------------------------------------------- #

fn spanValue(a: std.mem.Allocator, bs: usize, be: usize, line: usize, col: usize) error{OutOfMemory}!json.Value {
    const obj = try a.alloc(json.Value.Entry, 4);
    obj[0] = .{ .key = "byteEnd", .value = .{ .int = @intCast(be) } };
    obj[1] = .{ .key = "byteStart", .value = .{ .int = @intCast(bs) } };
    obj[2] = .{ .key = "col", .value = .{ .int = @intCast(col) } };
    obj[3] = .{ .key = "line", .value = .{ .int = @intCast(line) } };
    return .{ .object = obj };
}

pub fn diagnosticsToJson(a: std.mem.Allocator, diags: []const Diagnostic) error{OutOfMemory}![]u8 {
    const arr = try a.alloc(json.Value, diags.len);
    for (diags, 0..) |d, i| {
        const rel = try a.alloc(json.Value, d.related.len);
        for (d.related, 0..) |r, j| {
            const robj = try a.alloc(json.Value.Entry, 4);
            robj[0] = .{ .key = "decl", .value = .{ .string = r.decl } };
            robj[1] = .{ .key = "file", .value = .{ .string = r.file } };
            robj[2] = .{ .key = "message", .value = .{ .string = r.message } };
            robj[3] = .{ .key = "span", .value = try spanValue(a, r.span.byte_start, r.span.byte_end, r.span.line, r.span.col) };
            rel[j] = .{ .object = robj };
        }
        const obj = try a.alloc(json.Value.Entry, 7);
        obj[0] = .{ .key = "code", .value = .{ .string = d.code } };
        obj[1] = .{ .key = "decl", .value = .{ .string = d.decl } };
        obj[2] = .{ .key = "file", .value = .{ .string = d.file } };
        obj[3] = .{ .key = "message", .value = .{ .string = d.message } };
        obj[4] = .{ .key = "related", .value = .{ .array = rel } };
        obj[5] = .{ .key = "severity", .value = .{ .string = @tagName(d.severity) } };
        obj[6] = .{ .key = "span", .value = try spanValue(a, d.byte_start, d.byte_end, d.line, d.col) };
        arr[i] = .{ .object = obj };
    }
    const root_obj = try a.alloc(json.Value.Entry, 1);
    root_obj[0] = .{ .key = "diagnostics", .value = .{ .array = arr } };
    const root = json.Value{ .object = root_obj };
    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    root.writeCanonical(&aw.writer) catch return error.OutOfMemory;
    aw.writer.writeByte('\n') catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

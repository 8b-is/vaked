// GENESIS_SEAL: 7c242080
//! vakedz.check — 0011 type-system checker, slice 1: the conformance core.
//!
//! Faithful port of the conformance-class rules of vakedc/check.py (the
//! semantic spec). Ported in this slice:
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
//! Deferred to slice 2 (see check.py): capability refs + POLA (E-CAP-*,
//! W-POLA-EXCESS, W-CONFUSED-DEPUTY), egress (E-EGRESS-USE,
//! W-EGRESS-UNREFINED), closed-world ref resolution (E-REF-UNRESOLVED),
//! workflow topology (E-WORKFLOW-CYCLE/DEPTH), determinism
//! (E-DETERMINISM-EFFECT), ebpf intent (E-EBPF-*), generics
//! (E-GENERIC-INCONSISTENT).
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
    open: bool,
    origin_file: []const u8,
    decl_span: Span4,

    fn getField(self: *const SchemaSpec, name: []const u8) ?*const FieldSpec {
        for (self.fields) |*f| if (std.mem.eql(u8, f.name, name)) return f;
        return null;
    }
};

pub const CapabilitySpec = struct {
    domain: []const u8,
    grants: []const []const u8, // dedup'd, insertion order (Python: set)
    order_chains: []const []const []const u8,
    origin_file: []const u8,
    decl_span: Span4,
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
    caps: std.ArrayList(CapabilitySpec) = .empty,
    namespaces: std.ArrayList(NamespaceSpec) = .empty,

    pub fn getSchema(self: *const Registry, name: []const u8) ?*const SchemaSpec {
        for (self.schemas.items) |*s| if (std.mem.eql(u8, s.name, name)) return s;
        return null;
    }

    fn addSchema(self: *Registry, spec: SchemaSpec) error{OutOfMemory}!void {
        for (self.schemas.items) |*s| {
            if (std.mem.eql(u8, s.name, spec.name)) {
                s.* = spec; // later (user) overrides earlier (builtin)
                return;
            }
        }
        try self.schemas.append(self.a, spec);
    }

    fn addCapability(self: *Registry, spec: CapabilitySpec) error{OutOfMemory}!void {
        for (self.caps.items) |*c| {
            if (std.mem.eql(u8, c.domain, spec.domain)) {
                c.* = spec;
                return;
            }
        }
        try self.caps.append(self.a, spec);
    }

    fn addNamespace(self: *Registry, spec: NamespaceSpec) error{OutOfMemory}!void {
        for (self.namespaces.items) |*n| {
            if (std.mem.eql(u8, n.head, spec.head)) {
                n.* = spec;
                return;
            }
        }
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
            var replaced = false;
            for (fields.items) |*existing| {
                if (std.mem.eql(u8, existing.name, f.name)) {
                    existing.* = spec; // dict semantics: rebind keeps position
                    replaced = true;
                    break;
                }
            }
            if (!replaced) try fields.append(a, spec);
        },
        .open => is_open = true,
        else => {},
    };
    return .{
        .name = d.name,
        .fields = try fields.toOwnedSlice(a),
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

/// check.py `_render_vprop`. Python renders list/record values via `repr()`
/// of the value-prop dict; that exact text is not reproducible here, so those
/// arms render as placeholders (differential compares codes+positions).
fn renderValue(a: std.mem.Allocator, v: parser.Expr) error{OutOfMemory}![]const u8 {
    switch (v) {
        .literal => |l| return renderLiteral(a, l),
        .app => |ap| return ap.ref.dotted(a),
        .list => return "<list value>",
        .record => return "<record value>",
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
                const kind: u8 = if (i + 2 < n) body[i + 2] else 0;
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
                return try std.fmt.allocPrint(a, "extended group ((?{c}…)) is not in the bounded dialect", .{kind});
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
            const c = self.peek() orelse return atom;
            switch (c) {
                '?' => {
                    self.i += 1;
                    return self.node(.{ .rep = .{ .child = atom, .min = 0, .max = 1 } });
                },
                '*' => {
                    self.i += 1;
                    return self.node(.{ .rep = .{ .child = atom, .min = 0, .max = null } });
                },
                '+' => {
                    self.i += 1;
                    return self.node(.{ .rep = .{ .child = atom, .min = 1, .max = null } });
                },
                '{' => {
                    // {m} | {m,n} | {m,} — anything else is a literal '{'
                    const save = self.i;
                    self.i += 1;
                    const m = self.parseInt() orelse {
                        self.i = save;
                        return atom;
                    };
                    var max: ?u32 = m;
                    if (self.peek() == ',') {
                        self.i += 1;
                        max = self.parseInt(); // null ⇒ open-ended {m,}
                    }
                    if (self.peek() != '}') {
                        self.i = save;
                        return atom;
                    }
                    self.i += 1;
                    return self.node(.{ .rep = .{ .child = atom, .min = m, .max = max } });
                },
                else => return atom,
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
                    return self.node(.{ .char = escapedChar(e) });
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
                    lo = escapedChar(e);
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
                        hi = escapedChar(e);
                    } else {
                        hi = hc;
                        self.i += 1;
                    }
                    try items.append(self.a, .{ .range = .{ lo, hi } });
                } else {
                    try items.append(self.a, .{ .range = .{ lo, lo } });
                }
            }
            self.i += 1; // closing ']'
            return .{ .negated = negated, .items = try items.toOwnedSlice(self.a) };
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

    fn escapedChar(c: u8) u8 {
        return switch (c) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'f' => 0x0c,
            'v' => 0x0b,
            '0' => 0,
            else => c,
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

    const Compiler = struct {
        a: std.mem.Allocator,
        prog: std.ArrayList(Inst) = .empty,

        fn pc(self: *Compiler) u32 {
            return @intCast(self.prog.items.len);
        }

        fn emitNode(self: *Compiler, n: *const Node) error{ OutOfMemory, BadRegex }!void {
            switch (n.*) {
                .empty => {},
                .char => |c| try self.prog.append(self.a, .{ .char = c }),
                .any => try self.prog.append(self.a, .any),
                .class => |cls| try self.prog.append(self.a, .{ .class = cls }),
                .start => try self.prog.append(self.a, .assert_start),
                .end => try self.prog.append(self.a, .assert_end),
                .cat => |seq| for (seq) |ch| try self.emitNode(ch),
                .alt => |alts| {
                    var jmps: std.ArrayList(u32) = .empty;
                    defer jmps.deinit(self.a);
                    var i: usize = 0;
                    while (i < alts.len) : (i += 1) {
                        if (i + 1 < alts.len) {
                            const sp = self.pc();
                            try self.prog.append(self.a, .{ .split = .{ 0, 0 } });
                            self.prog.items[sp] = .{ .split = .{ self.pc(), 0 } };
                            try self.emitNode(alts[i]);
                            try jmps.append(self.a, self.pc());
                            try self.prog.append(self.a, .{ .jmp = 0 });
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
                            try self.prog.append(self.a, .{ .split = .{ 0, 0 } });
                            self.prog.items[sp] = .{ .split = .{ self.pc(), 0 } };
                            try splits.append(self.a, sp);
                            try self.emitNode(r.child);
                        }
                        const endpc = self.pc();
                        for (splits.items) |sp| self.prog.items[sp].split[1] = endpc;
                    } else {
                        // greedy star: L1: split(L2, L3); L2: e; jmp L1; L3:
                        const l1 = self.pc();
                        try self.prog.append(self.a, .{ .split = .{ 0, 0 } });
                        self.prog.items[l1] = .{ .split = .{ self.pc(), 0 } };
                        try self.emitNode(r.child);
                        try self.prog.append(self.a, .{ .jmp = l1 });
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
        try comp.prog.append(a, .match);
        const prog = comp.prog.items;

        // Pike VM without captures.
        var clist: std.ArrayList(u32) = .empty;
        var nlist: std.ArrayList(u32) = .empty;
        const on_c = try a.alloc(bool, prog.len);
        const on_n = try a.alloc(bool, prog.len);
        @memset(on_c, false);
        try addThread(prog, &clist, on_c, 0, 0, s.len, a);
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
                            try addThread(prog, &nlist, on_n, pcv + 1, pos + 1, s.len, a);
                    },
                    .any => {
                        if (pos < s.len and s[pos] != '\n')
                            try addThread(prog, &nlist, on_n, pcv + 1, pos + 1, s.len, a);
                    },
                    .class => |cls| {
                        if (pos < s.len and classMatch(cls, s[pos]))
                            try addThread(prog, &nlist, on_n, pcv + 1, pos + 1, s.len, a);
                    },
                    else => {},
                }
            }
            if (pos == s.len) return matched_here;
            std.mem.swap(std.ArrayList(u32), &clist, &nlist);
            @memcpy(on_c, on_n);
        }
        return false;
    }

    fn addThread(prog: []const Inst, list: *std.ArrayList(u32), seen: []bool, pcv: u32, pos: usize, len: usize, a: std.mem.Allocator) error{OutOfMemory}!void {
        if (seen[pcv]) return;
        seen[pcv] = true;
        switch (prog[pcv]) {
            .jmp => |t| try addThread(prog, list, seen, t, pos, len, a),
            .split => |ts| {
                try addThread(prog, list, seen, ts[0], pos, len, a);
                try addThread(prog, list, seen, ts[1], pos, len, a);
            },
            .assert_start => if (pos == 0) try addThread(prog, list, seen, pcv + 1, pos, len, a),
            .assert_end => if (pos == len) try addThread(prog, list, seen, pcv + 1, pos, len, a),
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
// The checker
// --------------------------------------------------------------------------- #

/// Kinds whose conformance schema is named differently from the kind
/// (check.py `_KIND_SCHEMA`).
fn kindSchemaName(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "network")) return "networkMembrane";
    return kind;
}

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
    diags: std.ArrayList(Diagnostic) = .empty,

    fn smapFor(self: *const Checker, f: []const u8) ?*const SourceMap {
        if (std.mem.eql(u8, f, self.file)) return &self.smap;
        if (std.mem.eql(u8, f, self.b_file)) return &self.b_smap;
        return null;
    }

    fn emit(self: *Checker, code: []const u8, file: []const u8, span: Span4, decl_label: []const u8, message: []const u8) error{OutOfMemory}!void {
        try self.diags.append(self.a, .{
            .code = code,
            .message = message,
            .file = file,
            .line = span.line,
            .col = span.col,
            .byte_start = span.bs,
            .byte_end = span.be,
            .decl = decl_label,
            .severity = .@"error",
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

    fn checkCapabilityWellformed(self: *Checker, spec: *const CapabilitySpec) error{OutOfMemory}!void {
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
        // 2/3. acyclicity (antisymmetry) of the closure
        if (try transitiveClosureCycle(self.a, spec.grants, spec.order_chains)) |cyc| {
            try self.emit("E-CAP-ORDER-CYCLE", spec.origin_file, dspan, label, try std.fmt.allocPrint(self.a, "capability `{s}`: order is cyclic (`{s}` and `{s}` are mutually ≤) — the relation must be a partial order", .{ spec.domain, cyc[0], cyc[1] }));
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
            // matches (regex) — applies to scalar string/path values
            for (f.refinements) |r| switch (r) {
                .matches => |rx| {
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

    // --- tree walk (check.py `_check_decl_tree`, slice-1 subset) ------------

    fn checkDeclTree(self: *Checker, decl: *const parser.Decl) error{OutOfMemory}!void {
        const kind = decl.kind;
        // Conformance for kinds that have a schema (skip the meta-kinds).
        if (!std.mem.eql(u8, kind, "schema") and !std.mem.eql(u8, kind, "capability")) {
            if (self.reg.getSchema(kindSchemaName(kind))) |schema| {
                try self.conformDecl(decl, schema);
            }
            // slice 2: _check_generics (E-GENERIC-INCONSISTENT)
        }
        // Mesh: conform each node body against meshNode (slice 2: capability
        // refs, attenuation, reachability, egress).
        if (std.mem.eql(u8, kind, "mesh")) {
            if (self.reg.getSchema("meshNode")) |ms| {
                for (decl.body) |st| switch (st) {
                    .node => |n| try self.conformNode(n, ms),
                    else => {},
                };
            }
        }
        // Workflow: conform each step body against workflowStep (slice 2:
        // agent-target refs, determinism, cycle/depth).
        if (std.mem.eql(u8, kind, "workflow")) {
            if (self.reg.getSchema("workflowStep")) |ws| {
                for (decl.body) |st| switch (st) {
                    .node => |n| try self.conformNode(n, ws),
                    else => {},
                };
            }
        }
        // slice 2: _check_ebpf_intent (E-EBPF-*)
        // Recurse into nested declarations.
        for (decl.body) |st| switch (st) {
            .decl => |inner| try self.checkDeclTree(inner),
            else => {},
        };
    }
};

fn strLess(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

/// check.py `_transitive_closure` — returns the first cycle pair (per this
/// port's deterministic iteration order) or null when the declared `<` chains
/// form a partial order. Python iterates hash sets here, so the PAIR REPORTED
/// on a cycle may differ from CPython run to run; the code and span match.
fn transitiveClosureCycle(a: std.mem.Allocator, grants: []const []const u8, chains: []const []const []const u8) error{OutOfMemory}!?[2][]const u8 {
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
    // a strict order forbids a < a (degenerate self-cycle)
    for (0..n) |gi| {
        for (succ[gi].items) |x| {
            if (x == gi) return .{ nodes.items[gi], nodes.items[gi] };
        }
    }
    // antisymmetry: a<=b and b<=a with a!=b ⇒ cycle
    for (0..n) |ai| {
        for (0..n) |bi| {
            if (ai != bi and reach[ai][bi] and reach[bi][ai]) {
                return .{ nodes.items[ai], nodes.items[bi] };
            }
        }
    }
    return null;
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

fn diagLess(_: void, x: Diagnostic, y: Diagnostic) bool {
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

/// Check Vaked `src` against the builtins catalog and return the sorted
/// diagnostics (check.py `check_source`, slice-1 rules). Allocate from an
/// arena that outlives the result.
pub fn checkSource(a: std.mem.Allocator, src: []const u8, filename: []const u8, b: Builtins) error{OutOfMemory}!CheckOutcome {
    const items = switch (try parseSource(a, src, filename)) {
        .ok => |items| items,
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
        const specs = try a.alloc(*const CapabilitySpec, reg.caps.items.len);
        for (reg.caps.items, 0..) |*s, i| specs[i] = s;
        std.sort.insertion(*const CapabilitySpec, specs, {}, struct {
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

    // Stage 4 (pre-walk) — name collisions, enriched from resolve's output.
    var infos: std.ArrayList(CollisionInfo) = .empty;
    try collectCollisionInfos(a, items, &infos);
    try enrichCollisions(&c, res.diagnostics, infos.items);

    // Stage 4b — walk every in-file declaration (conformance subset).
    for (items) |it| switch (it) {
        .decl => |d| try c.checkDeclTree(d),
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

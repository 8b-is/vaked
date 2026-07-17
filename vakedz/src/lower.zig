// GENESIS_SEAL: 7c242080
//! vakedz.lower — artifact generation (port of vakedc/lower.py, byte-parity).
//!
//! Lowers a *validated* graph to artifacts + a provenance manifest (0012).
//! Pure: no IO, no clock, no randomness — the caller writes `result.files`
//! (that contract, and the process-exit contract, live in main.zig).
//!
//! PORT COMPLETE. Every target `lower.py`'s REGISTRY can select is ported and
//! byte-identical to vakedc:
//!   * `nix.spine`       (emit_nix_spine,       L374)  -> flake.nix
//!   * `docs.runtime`    (emit_docs_runtime,    L644)  -> gen/RUNTIME.md
//!   * `zig.daemoncfg`   (emit_zig_daemoncfg,   L931)  -> gen/zig/<fiber>.json
//!   * `catalog.jsonl`   (emit_catalog_jsonl,   L1133) -> gen/catalog/<i>.jsonl
//!   * `sops.secrets`    (emit_sops_secrets,    L1299) -> gen/nixos/sops.nix
//!   * `host.resources`  (emit_host_resources,  L1332) -> gen/nixos/host-resources.nix
//!   * `nixos.service`   (emit_nixos_service,   L1365) -> gen/nixos/services.nix
//!   * `caddy.ingress`   (emit_caddy_ingress,   L1427) -> gen/caddy/ingress.nix
//!   * `oci.containers`  (emit_oci_containers,  L1500) -> gen/nixos/oci-containers.nix
//!   * `eventd.config`   (emit_eventd_config,   L1657) -> gen/eventd.json
//!   * `trust.config`    (emit_trust_config,    L1682) -> gen/trust.json
//!   * `memory.store`    (emit_memory_store,    L1764) -> gen/memory/<m>.json
//!   * `otp.supervision` (emit_otp_supervision, L1880) -> gen/otp/*.erl
//!   * `workflow.spec`   (emit_workflow_spec,   L2031) -> gen/workflow/<w>.json
//!   * `colmena.hive`    (emit_colmena_hive,    L2123) -> gen/colmena/hive.nix
//!   * `ebpf.policy`     (emit_ebpf_policy,     L2262) -> gen/ebpf.policy.json
//! plus the driver infrastructure: `_RuntimeView`, `enrich_graph`,
//! `ProvEntry`/`_build_provenance`, `inputs_hash` (a real sha256), and the
//! `provenance_json_text` pretty-printer.
//!
//! `crabcc.index` has no emitter of its own: its provenance entries are
//! produced inside `emitNixSpine` (the spine emitter), exactly as in Python.
//! `catalog.sqlite`, `otel.config`, `systemd.units` and `surface.launcher` are
//! the registry's DEFERRED rows — `emit_deferred` produces nothing and
//! `lower()` never dispatches them, so there is nothing to port. NOTE
//! `ebpf.policy` is NOT among them despite three stale docstrings in lower.py
//! saying so (L41, L1554, and the test's EMITTER_REGISTRY comment): its
//! registry row carries no `deferred=True` and L2452 dispatches it.
//!
//! FOUR serializers, deliberately distinct — reusing the wrong one produces
//! valid, wrong bytes that only a byte-diff catches:
//!   * `lib.json.writeCanonical` — compact `(",",":")`, emit order
//!     (catalog.jsonl rows);
//!   * `emitZigJson` — Python `_Ordered`, 2-space pretty, UNSORTED, one-line
//!     scalar arrays (zig.daemoncfg / eventd / memory / workflow / trust's
//!     top level);
//!   * `jsonDumpsDefault` / `emitZigValueDumps` — `json.dumps` defaults: ONE
//!     line, `(", ", ": ")` (trust.config's plain-dict entries);
//!   * `jsonDumpsIndentSorted` — `json.dumps(indent=2, sort_keys=True)`:
//!     pretty, keys SORTED, item separator without its trailing space
//!     (ebpf.policy).
//!
//! And TWO number rules: `_scalar_prop`/`_coerce_number` COERCES (docs.runtime,
//! zig.daemoncfg, trust/quorum, workflow) while `_nix_literal` renders the
//! stored string VERBATIM (the whole NixOS cohort). `2.0` is `2.0` under the
//! first and `2.0` under the second, but `007` is `7` under the first and `007`
//! under the second. See the Python-derived table in lower_test.zig.
//!
//! Determinism: graph node iteration is a StringHashMap walk (nondeterministic
//! order), so every output boundary sorts — `nodesSorted` (by id) mirrors
//! Python's `Graph.nodes_sorted`, and `children` walks the edge list in
//! insertion order, mirroring `Graph.children`'s insertion-ordered adjacency
//! index.
//!
//! Numbers: props store number literals as STRINGS (`{"lit":"number",
//! "value":"10"}`) — resolve.py `_value_to_props` never coerces. Every numeric
//! emission here therefore renders the string verbatim (Python's `_lit` returns
//! the string too, and `"%s" % "10"` is `10`). `_coerce_number` exists only for
//! the JSON-valued daemon configs, which are not in this slice.
//!
//! Memory: everything returned is allocated from the caller's allocator — pass
//! an arena.
const std = @import("std");
const lib = @import("lib");
const json = lib.json;
const graphmod = lib.graph;
const spanmod = lib.span;
const parser = @import("parser.zig");
const resolve_mod = @import("resolve.zig");

const Allocator = std.mem.Allocator;
const Error = error{OutOfMemory};

/// `(from_name, to_name)` — Python's `tuple[str, str]`. Lives here because its
/// producer `stepsEdges` does; passes.zig re-exports both.
pub const Edge = struct {
    from: []const u8,
    to: []const u8,
};

/// lower.py `_workflow_steps_edges` (L2004-2012): a workflow's `node` children
/// in declaration order, and the `routes_to` edges among them as
/// (from_name, to_name). Edge order is `graph.edges` order — Python iterates
/// the same insertion-ordered list.
///
/// This lives in lower.zig, not passes.zig, because that is where Python puts
/// it: `pass01_topology.py:16` does `from vakedc.lower import
/// _workflow_steps_edges`. passes depends on lower; not the reverse.
pub fn stepsEdges(
    a: Allocator,
    g: *const graphmod.Graph,
    wf: graphmod.GraphNode,
) Error!struct { steps: []const graphmod.GraphNode, edges: []const Edge } {
    const children = try childrenOf(a, g, wf.id);
    var steps: std.ArrayListUnmanaged(graphmod.GraphNode) = .empty;
    for (children) |n| {
        if (std.mem.eql(u8, n.kind, "node")) try steps.append(a, n);
    }
    const step_slice = try steps.toOwnedSlice(a);

    // Python `ids = {n.id: n.name for n in steps}` — a dict keyed by id, so a
    // duplicate id would keep the LAST name. Ids are unique in a built graph.
    var ids: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (step_slice) |s2| try ids.put(a, s2.id, s2.name);

    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    for (g.edges.items) |e| {
        if (!std.mem.eql(u8, e.label, "routes_to")) continue;
        const from = ids.get(e.source) orelse continue;
        const to = ids.get(e.target) orelse continue;
        try edges.append(a, .{ .from = from, .to = to });
    }
    return .{ .steps = step_slice, .edges = try edges.toOwnedSlice(a) };
}

/// lower.py `NIXPKGS_BASELINE_REV`: nixpkgs is emitted PINNED (0012 §4.1),
/// never a moving channel ref. The 40-hex value is a disclosed placeholder
/// (all-`b` = "baseline"); the committed flake.lock records the real rev.
pub const nixpkgs_baseline_rev = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

// --------------------------------------------------------------------------- //
// Generated header (0012 §6.1) — carries NO timestamp.
// --------------------------------------------------------------------------- //

/// lower.py `_header_file`: the source-file *basename* as it appears in the
/// §6.1 header (`operator-field.vaked`), never the full path the graph is keyed
/// by. Backslashes are normalized to '/' first, then the last segment is taken
/// (posixpath.basename over the normalized string).
fn headerFile(source_file: []const u8) []const u8 {
    var last: usize = 0;
    var found = false;
    for (source_file, 0..) |c, i| {
        if (c == '/' or c == '\\') {
            last = i + 1;
            found = true;
        }
    }
    return if (found) source_file[last..] else source_file;
}

/// lower.py `_header`.
fn header(a: Allocator, source_file: []const u8, decl: []const u8) Error![]const u8 {
    return std.fmt.allocPrint(a, "generated by Vaked from {s}:{s} — do not edit", .{ headerFile(source_file), decl });
}

// --------------------------------------------------------------------------- //
// Provenance entry
// --------------------------------------------------------------------------- //

/// lower.py `ProvEntry`: one provenance entry per emitted artifact or region
/// (0012 §6.2). `region == null` ⇒ the entry covers the whole artifact.
/// `inputs_projection` is the canonical projection `inputsHash` is computed
/// over (§2.1).
pub const ProvEntry = struct {
    artifact: []const u8,
    region: ?[]const u8,
    source_file: []const u8,
    decl: []const u8,
    span: spanmod.Span,
    emitter: []const u8,
    inputs_projection: json.Value,
};

// --------------------------------------------------------------------------- //
// Canonical JSON helpers
// --------------------------------------------------------------------------- //

fn entryKeyLess(_: void, x: json.Value.Entry, y: json.Value.Entry) bool {
    return std.mem.order(u8, x.key, y.key) == .lt;
}

/// lower.py `_canonical_value`: recursively canonicalize a JSON-able value —
/// object keys sorted, array order preserved (source order is meaningful).
/// Mirrors emit.py `_canon_value`, so a node's projection is stable regardless
/// of prop insertion order. Python sorts str keys by code point, which equals
/// byte order on UTF-8, so `std.mem.order` matches. Python's `sorted` is
/// stable; duplicate keys cannot occur in a props object, but `std.sort.block`
/// is used anyway to keep the tie behavior identical.
pub fn canonicalValue(a: Allocator, v: json.Value) Error!json.Value {
    switch (v) {
        .object => |obj| {
            const out = try a.alloc(json.Value.Entry, obj.len);
            for (obj, 0..) |e, i| {
                out[i] = .{ .key = e.key, .value = try canonicalValue(a, e.value) };
            }
            std.sort.block(json.Value.Entry, out, {}, entryKeyLess);
            return .{ .object = out };
        },
        .array => |arr| {
            const out = try a.alloc(json.Value, arr.len);
            for (arr, 0..) |x, i| out[i] = try canonicalValue(a, x);
            return .{ .array = out };
        },
        else => return v,
    }
}

/// lower.py `_canonical_projection_json`: the canonical JSON string a
/// projection is hashed over — sorted keys, compact separators,
/// `ensure_ascii=False`, no trailing newline. `writeCanonical` is exactly
/// `separators=(",",":")` + raw-UTF-8 passthrough; the sort is ours (the
/// writer never reorders).
pub fn canonicalProjectionJson(a: Allocator, projection: json.Value) Error![]u8 {
    const canon = try canonicalValue(a, projection);
    // `toOwned` writes into an Allocating writer: allocation is its only
    // failure mode, so every error collapses to OutOfMemory.
    return canon.toOwned(a) catch error.OutOfMemory;
}

/// lower.py `inputs_hash`: `"sha256-" + sha256(canonical_projection_json)`
/// (0012 §6.2) — a real, reproducible digest, not a placeholder.
pub fn inputsHash(a: Allocator, projection: json.Value) Error![]const u8 {
    const canonical = try canonicalProjectionJson(a, projection);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical, &digest, .{});
    return std.fmt.allocPrint(a, "sha256-{x}", .{&digest});
}

/// lower.py `_node_projection`: a node's kind + name + canonicalized props.
fn nodeProjection(a: Allocator, node: graphmod.GraphNode) Error!json.Value {
    const obj = try a.alloc(json.Value.Entry, 3);
    obj[0] = .{ .key = "kind", .value = .{ .string = node.kind } };
    obj[1] = .{ .key = "name", .value = .{ .string = node.name } };
    obj[2] = .{ .key = "props", .value = try canonicalValue(a, node.props) };
    return .{ .object = obj };
}

/// lower.py `_engine_projection`: the resolved-engine projection for a fiber's
/// `packages.<engine>` region (0012 §6.2). Keyed by the ENGINE, not the fiber
/// node — so this region's hash differs from the fiber-config region's even
/// though both attribute to the same `fiber` decl.
fn engineProjection(a: Allocator, engine_name: []const u8) Error!json.Value {
    const obj = try a.alloc(json.Value.Entry, 2);
    obj[0] = .{ .key = "engine", .value = .{ .string = engine_name } };
    obj[1] = .{ .key = "package", .value = .{ .string = try std.fmt.allocPrint(a, "packages.{s}", .{engine_name}) } };
    return .{ .object = obj };
}

// --------------------------------------------------------------------------- //
// Small graph-projection utilities (pure reads of already-resolved props)
// --------------------------------------------------------------------------- //

/// `graph.nodes_sorted()`: all nodes ordered by id. The StringHashMap walk is
/// nondeterministic, so this sort is load-bearing for determinism.
fn nodesSorted(a: Allocator, g: *const graphmod.Graph) Error![]graphmod.GraphNode {
    const nodes = try a.alloc(graphmod.GraphNode, g.nodes.count());
    var it = g.nodes.valueIterator();
    var i: usize = 0;
    while (it.next()) |n| : (i += 1) nodes[i] = n.*;
    std.sort.block(graphmod.GraphNode, nodes, {}, struct {
        fn less(_: void, x: graphmod.GraphNode, y: graphmod.GraphNode) bool {
            return std.mem.order(u8, x.id, y.id) == .lt;
        }
    }.less);
    return nodes;
}

/// lower.py `_children_of` / `Graph.children(parent_id, "contains")`: direct
/// `contains` children in source order. Python serves this from an adjacency
/// index built at edge-add time whose iteration order IS edge insertion order;
/// scanning `g.edges` (an insertion-ordered list) in order is byte-identical.
fn childrenOf(a: Allocator, g: *const graphmod.Graph, parent_id: []const u8) Error![]graphmod.GraphNode {
    var out: std.ArrayListUnmanaged(graphmod.GraphNode) = .empty;
    for (g.edges.items) |e| {
        if (!std.mem.eql(u8, e.label, "contains")) continue;
        if (!std.mem.eql(u8, e.source, parent_id)) continue;
        if (g.getNode(e.target)) |n| try out.append(a, n);
    }
    return out.toOwnedSlice(a);
}

/// lower.py `_by_kind`.
fn byKind(a: Allocator, nodes: []const graphmod.GraphNode, kind: []const u8) Error![]graphmod.GraphNode {
    var out: std.ArrayListUnmanaged(graphmod.GraphNode) = .empty;
    for (nodes) |n| {
        if (std.mem.eql(u8, n.kind, kind)) try out.append(a, n);
    }
    return out.toOwnedSlice(a);
}

/// The value of `key` in an object-valued props map, else null.
fn getProp(props: json.Value, key: []const u8) ?json.Value {
    switch (props) {
        .object => |obj| {
            for (obj) |e| {
                if (std.mem.eql(u8, e.key, key)) return e.value;
            }
            return null;
        },
        else => return null,
    }
}

fn objHas(v: json.Value, key: []const u8) bool {
    return getProp(v, key) != null;
}

/// lower.py `_ref`: the dotted ref string of a `{"ref": "..."}` prop value —
/// but ONLY when it is a bare ref (no `args`, no `record`), else null.
fn refOf(v: ?json.Value) ?[]const u8 {
    const val = v orelse return null;
    if (objHas(val, "args") or objHas(val, "record")) return null;
    const r = getProp(val, "ref") orelse return null;
    return switch (r) {
        .string => |s| s,
        else => null,
    };
}

/// lower.py `_lit`: the literal value of a `{"lit": ..., "value": ...}` prop.
/// The resolver always stores `value` as a string (numbers included), so this
/// returns the raw string. A `lit` prop with no `value` yields null, exactly
/// like Python's `raw.get("value")`.
fn litOf(v: ?json.Value) ?[]const u8 {
    const val = v orelse return null;
    if (!objHas(val, "lit")) return null;
    const value = getProp(val, "value") orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

/// lower.py `_str_list`: the string-literal values of a list prop (`views`,
/// `systems`, `formats`). A non-list prop yields an empty list.
fn strList(a: Allocator, v: ?json.Value) Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const val = v orelse return out.toOwnedSlice(a);
    switch (val) {
        .array => |arr| {
            for (arr) |x| {
                if (litOf(x)) |lv| try out.append(a, lv);
            }
        },
        else => {},
    }
    return out.toOwnedSlice(a);
}

/// lower.py `_app_call`: an application `f(args...)` (`github("x")` /
/// `raw.github("a","b")`) as `(ref, [arg-literals])`, else null.
///
/// `args` entries mirror Python's `[_lit(a) for a in prop["args"]]`, which
/// yields `None` for a non-literal argument — modeled as a null element.
const AppCall = struct {
    ref: []const u8,
    args: []const ?[]const u8,
};

fn appCall(a: Allocator, v: ?json.Value) Error!?AppCall {
    const val = v orelse return null;
    const r = getProp(val, "ref") orelse return null;
    const args_v = getProp(val, "args") orelse return null;
    const ref_s = switch (r) {
        .string => |s| s,
        else => return null,
    };
    const arr = switch (args_v) {
        .array => |x| x,
        else => return null,
    };
    const args = try a.alloc(?[]const u8, arr.len);
    for (arr, 0..) |x, i| args[i] = litOf(x);
    return AppCall{ .ref = ref_s, .args = args };
}

/// The first call argument as Python reads it: `call[1][0] if call[1] else ""`.
/// An empty arg list yields `""`. A present-but-non-literal first arg is `None`
/// in Python and would raise on use; we surface `""` rather than crash (the
/// callers all feed it into string formatting).
fn firstArg(call: AppCall) []const u8 {
    if (call.args.len == 0) return "";
    return call.args[0] orelse "";
}

/// lower.py `_record_entries`: the `[{"assign","op","value"}]` entries of a
/// record/record-app prop (e.g. `trust = pinned { commit = ...; sha256 = ... }`)
/// as `name -> value-literal`. Only scalar values are read.
const RecordEntries = struct {
    keys: []const []const u8,
    vals: []const ?[]const u8,

    fn get(self: RecordEntries, name: []const u8) ?[]const u8 {
        // Python builds a dict, so a duplicate name keeps the LAST binding.
        var i = self.keys.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.keys[i], name)) return self.vals[i];
        }
        return null;
    }
};

fn recordEntries(a: Allocator, v: ?json.Value) Error!RecordEntries {
    var keys: std.ArrayListUnmanaged([]const u8) = .empty;
    var vals: std.ArrayListUnmanaged(?[]const u8) = .empty;
    const val = v orelse return .{ .keys = &.{}, .vals = &.{} };
    const rec = getProp(val, "record") orelse return .{ .keys = &.{}, .vals = &.{} };
    const arr = switch (rec) {
        .array => |x| x,
        else => return .{ .keys = &.{}, .vals = &.{} },
    };
    for (arr) |e| {
        const assign = getProp(e, "assign") orelse continue;
        const name = switch (assign) {
            .string => |s| s,
            else => continue,
        };
        try keys.append(a, name);
        try vals.append(a, litOf(getProp(e, "value")));
    }
    return .{ .keys = try keys.toOwnedSlice(a), .vals = try vals.toOwnedSlice(a) };
}

// --------------------------------------------------------------------------- //
// Runtime decomposition — find the runtime node and its child decls.
// --------------------------------------------------------------------------- //

/// lower.py `_RuntimeView`.
pub const RuntimeView = struct {
    runtime: graphmod.GraphNode,
    indexes: []graphmod.GraphNode = &.{},
    streams: []graphmod.GraphNode = &.{},
    fibers: []graphmod.GraphNode = &.{},
    surfaces: []graphmod.GraphNode = &.{},
    parallels: []graphmod.GraphNode = &.{},
    // NixOS-deployment cohort (#1-#6).
    services: []graphmod.GraphNode = &.{},
    secrets: []graphmod.GraphNode = &.{},
    host_resources: []graphmod.GraphNode = &.{},
    ingresses: []graphmod.GraphNode = &.{},
    containers: []graphmod.GraphNode = &.{},
    // Runtime plane (#18/#24/#27).
    memories: []graphmod.GraphNode = &.{},
    workflows: []graphmod.GraphNode = &.{},
    // Network membranes (the ebpf.policy slice; 0012 §7).
    networks: []graphmod.GraphNode = &.{},
    // Deployment targets (#28 slice 3 / #51).
    hosts: []graphmod.GraphNode = &.{},
    // Authority graphs — principal grant-sets (0011 §4.4 / 0012 §5.1).
    meshes: []graphmod.GraphNode = &.{},
    // v0.5 trio: trust / quorum / probe topology.
    trusts: []graphmod.GraphNode = &.{},
    quorums: []graphmod.GraphNode = &.{},
    probes: []graphmod.GraphNode = &.{},
};

/// lower.py `_runtime_view`: the FIRST `runtime` node in id order, plus its
/// direct `contains` children partitioned by kind. Null when the graph declares
/// no runtime.
pub fn runtimeView(a: Allocator, g: *const graphmod.Graph) Error!?RuntimeView {
    const all = try nodesSorted(a, g);
    var runtime: ?graphmod.GraphNode = null;
    for (all) |n| {
        if (std.mem.eql(u8, n.kind, "runtime")) {
            runtime = n;
            break;
        }
    }
    const rt = runtime orelse return null;
    const children = try childrenOf(a, g, rt.id);
    return RuntimeView{
        .runtime = rt,
        .indexes = try byKind(a, children, "index"),
        .streams = try byKind(a, children, "stream"),
        .fibers = try byKind(a, children, "fiber"),
        .surfaces = try byKind(a, children, "surface"),
        .parallels = try byKind(a, children, "parallel"),
        .services = try byKind(a, children, "service"),
        .secrets = try byKind(a, children, "secret"),
        .host_resources = try byKind(a, children, "hostResource"),
        .ingresses = try byKind(a, children, "ingress"),
        .containers = try byKind(a, children, "container"),
        .memories = try byKind(a, children, "memory"),
        .workflows = try byKind(a, children, "workflow"),
        .networks = try byKind(a, children, "network"),
        .hosts = try byKind(a, children, "host"),
        .meshes = try byKind(a, children, "mesh"),
        .trusts = try byKind(a, children, "trust"),
        .quorums = try byKind(a, children, "quorum"),
        .probes = try byKind(a, children, "probe"),
    };
}

/// lower.py `_index_emit_targets`: the dotted `emit` target refs of an index.
fn indexEmitTargets(a: Allocator, index_node: graphmod.GraphNode) Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const emit = getProp(index_node.props, "emit") orelse return out.toOwnedSlice(a);
    switch (emit) {
        .array => |arr| {
            for (arr) |x| {
                if (refOf(x)) |r| try out.append(a, r);
            }
        },
        else => {},
    }
    return out.toOwnedSlice(a);
}

fn hasTarget(targets: []const []const u8, want: []const u8) bool {
    for (targets) |t| {
        if (std.mem.eql(u8, t, want)) return true;
    }
    return false;
}

/// lower.py `_index_is_pinned`: true when the index declares
/// `trust = pinned { … }` (0012 §4.2). NOTE: this reads `trust["ref"] ==
/// "pinned"` directly, NOT via `_ref` — a record-carrying app still counts.
fn indexIsPinned(index_node: graphmod.GraphNode) bool {
    const trust = getProp(index_node.props, "trust") orelse return false;
    const r = getProp(trust, "ref") orelse return false;
    return switch (r) {
        .string => |s| std.mem.eql(u8, s, "pinned"),
        else => false,
    };
}

/// lower.py `_fiber_engine_name`.
fn fiberEngineName(fiber_node: graphmod.GraphNode) ?[]const u8 {
    return refOf(getProp(fiber_node.props, "engine"));
}

// --------------------------------------------------------------------------- //
// Nix rendering helpers (#7 splice class)
// --------------------------------------------------------------------------- //

/// lower.py `_nix_str`: a safe Nix double-quoted string literal. Neutralizes
/// the three sequences active inside `"..."` — backslash (FIRST), `"`, and `${`
/// antiquotation — so host-controlled values can never inject Nix. Backslash
/// MUST be escaped before the others.
pub fn nixStr(a: Allocator, s: []const u8) Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.append(a, '"');
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '\\') {
            try out.appendSlice(a, "\\\\");
        } else if (c == '"') {
            try out.appendSlice(a, "\\\"");
        } else if (c == '$' and i + 1 < s.len and s[i + 1] == '{') {
            // Python replaces the two-character sequence "${" with "\\${".
            try out.appendSlice(a, "\\${");
            i += 1;
        } else {
            try out.append(a, c);
        }
    }
    try out.append(a, '"');
    return out.toOwnedSlice(a);
}

/// lower.py `_is_nix_bare_ident`: `[A-Za-z_][A-Za-z0-9_'-]*`, ASCII only.
fn isNixBareIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    const c0 = s[0];
    if (!(std.ascii.isAlphabetic(c0) or c0 == '_')) return false;
    for (s[1..]) |c| {
        if (c > 127) return false;
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '\'' or c == '-')) return false;
    }
    return true;
}

/// lower.py `_nix_attr_key`: render `name` as a SINGLE Nix attribute key. A
/// bare identifier is emitted verbatim; anything else — most importantly a
/// dotted ref like `pkgs.umami`, which would otherwise splice into a NESTED
/// attrpath (the #7 worked-example bug) — becomes a quoted string key, so it
/// stays exactly one attribute and the emitted Nix stays well-formed.
pub fn nixAttrKey(a: Allocator, name: []const u8) Error![]const u8 {
    return if (isNixBareIdent(name)) name else nixStr(a, name);
}

/// lower.py `_nix_source_slug`: `github("owner/repo")` -> a deterministic
/// input-name slug (the repo's last path segment with `.`/`_` normalized to
/// `-`, so it is a valid Nix attr fragment).
fn nixSourceSlug(a: Allocator, dotted: []const u8) Error![]const u8 {
    // Python: dotted.rsplit("/", 1)[-1] — the segment after the LAST '/', or
    // the whole string when there is none.
    var repo = dotted;
    if (std.mem.lastIndexOfScalar(u8, dotted, '/')) |i| repo = dotted[i + 1 ..];
    const slug = try a.dupe(u8, repo);
    for (slug) |*c| {
        if (c.* == '.' or c.* == '_') c.* = '-';
    }
    return slug;
}

// --------------------------------------------------------------------------- //
// Line buffer — the emitters build `lines` then "\n".join(lines) + "\n".
// --------------------------------------------------------------------------- //

const Lines = struct {
    a: Allocator,
    items: std.ArrayListUnmanaged([]const u8) = .empty,

    fn init(a: Allocator) Lines {
        return .{ .a = a };
    }

    fn add(self: *Lines, s: []const u8) Error!void {
        try self.items.append(self.a, s);
    }

    fn addFmt(self: *Lines, comptime f: []const u8, args: anytype) Error!void {
        try self.items.append(self.a, try std.fmt.allocPrint(self.a, f, args));
    }

    /// `"\n".join(lines) + "\n"`.
    fn text(self: *Lines) Error![]const u8 {
        const joined = try std.mem.join(self.a, "\n", self.items.items);
        return std.mem.concat(self.a, u8, &.{ joined, "\n" });
    }
};

// --------------------------------------------------------------------------- //
// Emitter result
// --------------------------------------------------------------------------- //

pub const File = struct {
    path: []const u8,
    content: []const u8,
};

pub const Emitted = struct {
    files: []const File,
    entries: []const ProvEntry,
};

// --------------------------------------------------------------------------- //
// Emitter: nix.spine (ALWAYS) — flake.nix + the deferred surface stub.
// --------------------------------------------------------------------------- //

/// lower.py `emit_nix_spine` (0012 §4). ALWAYS runs. The flake outputs are a
/// pure function of the runtime node and its children; the surface launcher is
/// the §7 deferred no-op stub.
pub fn emitNixSpine(a: Allocator, g: *const graphmod.Graph, source_file: []const u8) Error!Emitted {
    const rv_opt = try runtimeView(a, g);
    const rv = rv_opt orelse return .{ .files = &.{}, .entries = &.{} };
    const runtime = rv.runtime;
    const sf = source_file;
    const rt_name = runtime.name;

    // --- inputs: nixpkgs (pinned baseline) + one per source ---------------- //
    const systems = try strList(a, getProp(runtime.props, "systems"));
    const systems_nix = try joinQuoted(a, systems, " ");

    var L = Lines.init(a);
    try L.addFmt("# {s}", .{try header(a, sf, try std.fmt.allocPrint(a, "runtime {s}", .{rt_name}))});
    try L.add("#");
    try L.add("# Expected-output fixture (no compiler exists yet) — see ./README.md and");
    try L.add("# docs/language/0012-lowering.md §4 (the Nix spine). Edits belong in the source");
    try L.add("# .vaked file, not here.");
    try L.add("{");
    try L.addFmt("  description = \"{s} — generated by Vaked\";", .{rt_name});
    try L.add("");
    try L.add("  inputs = {");
    try L.add("    # nixpkgs is emitted pinned to the toolchain's baseline rev (0012 §4.1): an");
    try L.add("    # explicit rev, never a moving channel ref. The 40-hex value below is a");
    try L.add("    # disclosed placeholder (all-`b` = \"baseline\"; see ./README.md); the");
    try L.add("    # committed flake.lock (produced at first build) records the real resolution.");
    try L.addFmt("    nixpkgs.url = \"github:NixOS/nixpkgs/{s}\";", .{nixpkgs_baseline_rev});

    // For each index: emit its source inputs.
    for (rv.indexes) |idx| {
        const src = getProp(idx.props, "source");
        if (indexIsPinned(idx)) {
            // raw.github(owner, file) + trust = pinned{commit, sha256}
            const call = try appCall(a, src);
            const owner = if (call) |c| firstArg(c) else "";
            try L.add("");
            try L.addFmt("    # index {s} — trust = pinned {{ commit, sha256 }} (0012 §4.2):", .{idx.name});
            try L.add("    # commit pins the rev; sha256 is recorded as the lock entry's narHash so the");
            try L.add("    # build verifies the fetch. raw.github(...) => flake = false.");
            try L.addFmt("    {s}-src = {{", .{idx.name});
            try L.addFmt("      url = \"github:{s}/<commit>\"; # trust.pinned.commit", .{owner});
            try L.add("      flake = false;");
            try L.add("    };");
        } else {
            // source = [github(...), ...] (unpinned)
            const sources = try sourceList(a, src);
            try L.add("");
            try L.addFmt("    # index {s} — sources (unpinned; flake.lock records the resolved rev).", .{idx.name});
            try L.add("    # 0012 §4.2: each index source becomes a flake input.");
            for (sources) |s| {
                const call = (try appCall(a, s)) orelse continue;
                const owner_repo = firstArg(call);
                const slug = try nixSourceSlug(a, owner_repo);
                try L.addFmt("    {s}-src-{s} = {{ url = \"github:{s}\"; flake = false; }};", .{ idx.name, slug, owner_repo });
            }
        }
    }
    try L.add("  };");
    try L.add("");
    try L.add("  outputs = { self, nixpkgs, ... }@inputs:");
    try L.add("    let");
    try L.addFmt("      # runtime {s} — systems = [{s}]", .{ rt_name, try joinQuoted(a, systems, ", ") });
    try L.addFmt("      systems = [ {s} ];", .{systems_nix});
    try L.add("      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);");
    try L.add("    in");
    try L.add("    {");
    try L.add("      # nixosModules.<runtime> — wires the OTP/Zig daemons and references the");
    try L.add("      # gen/ artifacts as installed files (0012 §4.3).");
    try L.addFmt("      nixosModules.{s} = import ./nixos/{s}.nix {{", .{ try nixAttrKey(a, rt_name), rt_name });
    try L.add("        # NixOS module fixture is described in 0012 §4.3; not emitted as a");
    try L.add("        # separate file in this fixture set (interface only).");
    try L.add("        inherit self;");
    try L.add("      };");
    try L.add("");
    try L.add("      packages = forAllSystems (system:");
    try L.add("        let pkgs = nixpkgs.legacyPackages.${system};");
    try L.add("        in {");

    // packages: engines (from fibers, source order), then crabcc index derivations.
    var seen_engines: std.ArrayListUnmanaged([]const u8) = .empty;
    for (rv.fibers) |fib| {
        const eng = fiberEngineName(fib) orelse continue;
        if (containsStr(seen_engines.items, eng)) continue;
        try seen_engines.append(a, eng);
        try L.addFmt("          # engine {s} (fiber {s}: engine = {s}) — built Zig pkg.", .{ eng, fib.name, eng });
        try L.addFmt("          {s} = pkgs.callPackage ./pkgs/{s}.nix {{ }};", .{ try nixAttrKey(a, eng), eng });
        try L.add("");
    }

    for (rv.indexes) |idx| {
        const targets = try indexEmitTargets(a, idx);
        if (!hasTarget(targets, "nix.derivation")) continue;
        const normalize = refOf(getProp(idx.props, "normalize"));
        var cat_targets: std.ArrayListUnmanaged([]const u8) = .empty;
        for (targets) |t| {
            if (std.mem.startsWith(u8, t, "catalog.")) try cat_targets.append(a, t);
        }
        // `" ".join("--emit " + t.split(".", 1)[1] for t in cat_targets)`
        var emit_parts: std.ArrayListUnmanaged([]const u8) = .empty;
        for (cat_targets.items) |t| {
            const rest = t[std.mem.indexOfScalar(u8, t, '.').? + 1 ..];
            try emit_parts.append(a, try std.fmt.allocPrint(a, "--emit {s}", .{rest}));
        }
        const emit_flags = try std.mem.join(a, " ", emit_parts.items);

        try L.addFmt("          # index {s}, emit ∋ nix.derivation (0012 §5.3a) — CrabCC index", .{idx.name});
        try L.add("          # derivation; runs crabcc at build time over the pinned sources with");
        try L.addFmt("          # normalize = {s}.", .{optStr(normalize)});
        try L.addFmt("          {s} = pkgs.stdenv.mkDerivation {{", .{try nixAttrKey(a, try std.fmt.allocPrint(a, "{s}-crabcc-index", .{idx.name}))});
        try L.addFmt("            pname = \"{s}-crabcc-index\";", .{idx.name});
        try L.add("            version = \"0\";");
        try L.add("            srcs = [");
        const sources = try sourceList(a, getProp(idx.props, "source"));
        for (sources) |s| {
            const call = (try appCall(a, s)) orelse continue;
            const owner_repo = firstArg(call);
            const slug = try nixSourceSlug(a, owner_repo);
            try L.addFmt("              inputs.{s}-src-{s}", .{ idx.name, slug });
        }
        try L.add("            ];");
        try L.add("            nativeBuildInputs = [ pkgs.crabcc ];");
        try L.add("            buildPhase = ''");
        // `normalize.split(".", 1)[1] if normalize and "." in normalize else normalize`
        var norm_arg: ?[]const u8 = normalize;
        if (normalize) |nrm| {
            if (std.mem.indexOfScalar(u8, nrm, '.')) |i| norm_arg = nrm[i + 1 ..];
        }
        try L.addFmt("              # normalize = {s} ; emit = {s}", .{ optStr(normalize), try std.mem.join(a, ", ", cat_targets.items) });
        try L.addFmt("              crabcc index build --normalize {s} \\", .{optStr(norm_arg)});
        try L.addFmt("                {s} \\", .{emit_flags});
        try L.add("                --out $out");
        try L.add("            '';");
        try L.add("          };");
    }
    try L.add("        });");
    try L.add("");
    try L.add("      apps = forAllSystems (system:");
    try L.add("        let pkgs = nixpkgs.legacyPackages.${system};");
    try L.add("        in {");
    // surfaces -> deferred stub apps (0012 §7).
    for (rv.surfaces) |surf| {
        const mode = refOf(getProp(surf.props, "mode"));
        try L.addFmt("          # surface {s} (mode = {s}) — launcher app.", .{ surf.name, optStr(mode) });
        try L.add("          # 0012 §7: surface launcher body is DEFERRED (no-op today). The slot");
        try L.add("          # exists so the registry test stays honest, but the mapping (raylib");
        try L.add("          # host integration) is not yet specified. The deferred body is derived");
        try L.add("          # from NOTHING but the surface decl name: a stub that exits non-zero");
        try L.add("          # with the standard deferral message — no real launcher is wired, and");
        try L.add("          # it does not route through any engine/fiber package.");
        try L.addFmt("          {s} = {{", .{try nixAttrKey(a, surf.name)});
        try L.add("            type = \"app\";");
        try L.addFmt("            program = \"${{pkgs.writeShellScript \"{s}-launcher-deferred\" ''", .{surf.name});
        try L.add("              echo \"vaked: surface launcher lowering deferred (0012 §7)\" >&2");
        try L.add("              exit 1");
        try L.add("            ''}\";");
        try L.add("          };");
    }
    try L.add("        });");
    try L.add("");
    try L.add("      devShells = forAllSystems (system:");
    try L.add("        let pkgs = nixpkgs.legacyPackages.${system};");
    try L.add("        in {");
    try L.add("          default = pkgs.mkShell {");
    // toolchains: zig if any engine, crabcc if any nix.derivation index.
    var tool_comment_parts: std.ArrayListUnmanaged([]const u8) = .empty;
    var tool_pkgs: std.ArrayListUnmanaged([]const u8) = .empty;
    if (seen_engines.items.len > 0) {
        try tool_comment_parts.append(a, "zig (engines)");
        try tool_pkgs.append(a, "pkgs.zig");
    }
    var any_drv = false;
    for (rv.indexes) |i| {
        if (hasTarget(try indexEmitTargets(a, i), "nix.derivation")) any_drv = true;
    }
    if (any_drv) {
        try tool_comment_parts.append(a, "crabcc (index)");
        try tool_pkgs.append(a, "pkgs.crabcc");
    }
    try L.addFmt("            # toolchains the runtime needs: {s}.", .{try std.mem.join(a, ", ", tool_comment_parts.items)});
    try L.addFmt("            packages = [ {s} ];", .{try std.mem.join(a, " ", tool_pkgs.items)});
    try L.add("          };");
    try L.add("        });");
    try L.add("    };");
    try L.add("}");

    const text = try L.text();
    const files = try a.alloc(File, 1);
    files[0] = .{ .path = "flake.nix", .content = text };

    // --- provenance entries: structural flake-output layout order (0012 §6.2) //
    // Order: nixosModules -> pinned inputs (source order) -> packages.crabcc-index
    // (source order) -> packages.<engine> (fiber source order) -> apps.<surface>.
    var entries: std.ArrayListUnmanaged(ProvEntry) = .empty;
    try entries.append(a, .{
        .artifact = "flake.nix",
        .region = try std.fmt.allocPrint(a, "nixosModules.{s}", .{rt_name}),
        .source_file = sf,
        .decl = try std.fmt.allocPrint(a, "runtime {s}", .{rt_name}),
        .span = runtime.provenance.?.span,
        .emitter = "nix.spine",
        .inputs_projection = try nodeProjection(a, runtime),
    });
    for (rv.indexes) |idx| {
        if (!indexIsPinned(idx)) continue;
        try entries.append(a, .{
            .artifact = "flake.nix",
            .region = try std.fmt.allocPrint(a, "inputs.{s}-src", .{idx.name}),
            .source_file = sf,
            .decl = try std.fmt.allocPrint(a, "index {s}", .{idx.name}),
            .span = idx.provenance.?.span,
            .emitter = "nix.spine",
            .inputs_projection = try nodeProjection(a, idx),
        });
    }
    for (rv.indexes) |idx| {
        if (!hasTarget(try indexEmitTargets(a, idx), "nix.derivation")) continue;
        try entries.append(a, .{
            .artifact = "flake.nix",
            .region = try std.fmt.allocPrint(a, "packages.{s}-crabcc-index", .{idx.name}),
            .source_file = sf,
            .decl = try std.fmt.allocPrint(a, "index {s}", .{idx.name}),
            .span = idx.provenance.?.span,
            .emitter = "crabcc.index",
            .inputs_projection = try nodeProjection(a, idx),
        });
    }
    var seen: std.ArrayListUnmanaged([]const u8) = .empty;
    for (rv.fibers) |fib| {
        const eng = fiberEngineName(fib) orelse continue;
        if (containsStr(seen.items, eng)) continue;
        try seen.append(a, eng);
        try entries.append(a, .{
            .artifact = "flake.nix",
            .region = try std.fmt.allocPrint(a, "packages.{s}", .{eng}),
            .source_file = sf,
            .decl = try std.fmt.allocPrint(a, "fiber {s}", .{fib.name}),
            .span = fib.provenance.?.span,
            .emitter = "nix.spine",
            .inputs_projection = try engineProjection(a, eng),
        });
    }
    for (rv.surfaces) |surf| {
        try entries.append(a, .{
            .artifact = "flake.nix",
            .region = try std.fmt.allocPrint(a, "apps.{s}", .{surf.name}),
            .source_file = sf,
            .decl = try std.fmt.allocPrint(a, "surface {s}", .{surf.name}),
            .span = surf.provenance.?.span,
            .emitter = "nix.spine",
            .inputs_projection = try nodeProjection(a, surf),
        });
    }
    return .{ .files = files, .entries = try entries.toOwnedSlice(a) };
}

/// Python's `src if isinstance(src, list) else ([src] if src else [])` — a list
/// prop stays as-is, a single prop is wrapped, a missing prop is empty.
fn sourceList(a: Allocator, src: ?json.Value) Error![]const json.Value {
    const v = src orelse return &.{};
    switch (v) {
        .array => |arr| return arr,
        .null => return &.{},
        else => {
            const one = try a.alloc(json.Value, 1);
            one[0] = v;
            return one;
        },
    }
}

/// `sep.join('"%s"' % s for s in items)`.
fn joinQuoted(a: Allocator, items: []const []const u8, sep: []const u8) Error![]const u8 {
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    for (items) |s| try parts.append(a, try std.fmt.allocPrint(a, "\"{s}\"", .{s}));
    return std.mem.join(a, sep, parts.items);
}

/// Python renders `None` as the four characters `None` under `"%s"`.
fn optStr(s: ?[]const u8) []const u8 {
    return s orelse "None";
}

fn containsStr(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| {
        if (std.mem.eql(u8, h, needle)) return true;
    }
    return false;
}

// --------------------------------------------------------------------------- //
// Emitter: docs.runtime (ALWAYS, on presence of the runtime) — gen/RUNTIME.md.
// --------------------------------------------------------------------------- //

/// lower.py `_md_code`.
fn mdCode(a: Allocator, s: []const u8) Error![]const u8 {
    return std.fmt.allocPrint(a, "`{s}`", .{s});
}

/// `_md_code` of an optional, matching Python's `_md_code(None)` == "`None`".
fn mdCodeOpt(a: Allocator, s: ?[]const u8) Error![]const u8 {
    return mdCode(a, optStr(s));
}

/// lower.py `_index_source_render`: an index's source(s) for the Indexes table.
fn indexSourceRender(a: Allocator, idx: graphmod.GraphNode) Error![]const u8 {
    const src = getProp(idx.props, "source");
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    const list: []const json.Value = blk: {
        const v = src orelse break :blk &.{};
        switch (v) {
            .array => |arr| break :blk arr,
            else => {
                const one = try a.alloc(json.Value, 1);
                one[0] = v;
                break :blk one;
            },
        }
    };
    for (list) |s| {
        const call = (try appCall(a, s)) orelse continue;
        var args: std.ArrayListUnmanaged([]const u8) = .empty;
        for (call.args) |arg| try args.append(a, try std.fmt.allocPrint(a, "\"{s}\"", .{optStr(arg)}));
        try parts.append(a, try std.fmt.allocPrint(a, "{s}({s})", .{ call.ref, try std.mem.join(a, ", ", args.items) }));
    }
    var coded: std.ArrayListUnmanaged([]const u8) = .empty;
    for (parts.items) |p| try coded.append(a, try mdCode(a, p));
    return std.mem.join(a, ", ", coded.items);
}

/// lower.py `_render_ref_list`: a list of refs (`input = [stream.a, graph.b]`)
/// as comma-joined code spans. A single (non-list) ref prop renders as one.
fn renderRefList(a: Allocator, prop: ?json.Value) Error![]const u8 {
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    const v = prop orelse return "";
    switch (v) {
        .array => |arr| {
            for (arr) |x| {
                if (refOf(x)) |r| try parts.append(a, try mdCode(a, r));
            }
        },
        else => {
            if (refOf(v)) |r| try parts.append(a, try mdCode(a, r));
        },
    }
    return std.mem.join(a, ", ", parts.items);
}

/// lower.py `_implied_membrane`: the implied membrane for a stream source
/// channel (0012 §5.1).
fn impliedMembrane(source: ?[]const u8) []const u8 {
    const s = source orelse return "—";
    if (std.mem.startsWith(u8, s, "agentGuardd.")) return "`ebpf` (agent-guardd)";
    if (std.mem.startsWith(u8, s, "agentpipe.")) return "`media` capture";
    return "—";
}

/// lower.py `_fiber_policy_fields` + `_render_policy`: a fiber's `policy { … }`
/// summary, projected in SOURCE order from the `policy` prop that
/// `enrichGraph` attaches (the bare config-block statement the minimal
/// resolver drops).
///
/// Value rendering mirrors Python's `_scalar_prop` + the `_render_policy`
/// isinstance ladder:
///   * bool  -> `k = true`      (a `{"lit":"bool","value":"true"}` prop)
///   * list  -> `k = ["a", "b"]`
///   * other -> `k = "v"`       (strings AND numbers — `_coerce_number` turns
///              "10" into 10, and `'%s = "%s"' % (k, 10)` is `k = "10"`, so a
///              number still renders quoted. Bug-compatible on purpose.)
fn renderPolicy(a: Allocator, fiber: graphmod.GraphNode) Error![]const u8 {
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    const arr: []const json.Value = blk: {
        const pol = getProp(fiber.props, "policy") orelse break :blk &.{};
        const rec = getProp(pol, "record") orelse break :blk &.{};
        switch (rec) {
            .array => |x| break :blk x,
            else => break :blk &.{},
        }
    };
    for (arr) |e| {
        const assign = getProp(e, "assign") orelse continue;
        const name = switch (assign) {
            .string => |s| s,
            else => continue,
        };
        const raw = getProp(e, "value");
        try parts.append(a, try renderPolicyValue(a, name, raw));
    }
    if (parts.items.len == 0) return "—";
    const inner = try std.mem.join(a, "`, `", parts.items);
    return std.mem.concat(a, u8, &.{ "`", inner, "`" });
}

fn renderPolicyValue(a: Allocator, name: []const u8, raw: ?json.Value) Error![]const u8 {
    const v = raw orelse return std.fmt.allocPrint(a, "{s} = \"None\"", .{name});
    // list prop -> `k = ["a", "b"]` (elements via _scalar_prop, then '"%s"')
    switch (v) {
        .array => |arr| {
            var items: std.ArrayListUnmanaged([]const u8) = .empty;
            for (arr) |x| {
                try items.append(a, try std.fmt.allocPrint(a, "\"{s}\"", .{try scalarPropStr(a, x)}));
            }
            return std.fmt.allocPrint(a, "{s} = [{s}]", .{ name, try std.mem.join(a, ", ", items.items) });
        },
        else => {},
    }
    // bool literal -> `k = true` / `k = false`
    if (getProp(v, "lit")) |kind| {
        const k = switch (kind) {
            .string => |s| s,
            else => "",
        };
        if (std.mem.eql(u8, k, "bool") or std.mem.eql(u8, k, "boolean")) {
            const val = litOf(v) orelse "";
            const b = std.mem.eql(u8, val, "true");
            return std.fmt.allocPrint(a, "{s} = {s}", .{ name, if (b) "true" else "false" });
        }
    }
    return std.fmt.allocPrint(a, "{s} = \"{s}\"", .{ name, try scalarPropStr(a, v) });
}

/// lower.py `_scalar_prop`, rendered through Python's `"%s"`. Numbers stay
/// STRINGS in props; `_coerce_number` parses "10" -> 10 and `%s` prints `10`,
/// so passing the stored string through is byte-identical for every integer
/// literal. Floats differ only where Python's `repr(float)` would (e.g.
/// "1.50" -> 1.5); handled explicitly below.
fn scalarPropStr(a: Allocator, v: json.Value) Error![]const u8 {
    if (getProp(v, "lit")) |kind| {
        const k = switch (kind) {
            .string => |s| s,
            else => "",
        };
        const val = litOf(v) orelse return "None";
        if (std.mem.eql(u8, k, "number")) return coerceNumberStr(a, val);
        if (std.mem.eql(u8, k, "bool") or std.mem.eql(u8, k, "boolean")) {
            return if (std.mem.eql(u8, val, "true")) "True" else "False";
        }
        return val;
    }
    if (refOf(v)) |r| return r;
    return "None";
}

/// lower.py `_coerce_number` composed with Python's `"%s"` (i.e. `str()`).
///
///     if "." in value or "e" in value or "E" in value: return float(value)
///     return int(value)                       # ValueError -> return value
///
/// The branch is chosen on the STRING, exactly like Python — not on the lexer's
/// literal kind.
///
/// NOTE both branches are reachable from `docs.runtime` TODAY: `fiberPolicy` is
/// an OPEN schema (vaked/schema/builtins.vaked), so an undeclared policy field
/// of any literal type flows enrichGraph -> renderPolicyValue -> RUNTIME.md.
/// The differential is structurally blind to it (no fixture carries a float or
/// a leading zero), so the unit-test table in lower_test.zig is the only gate —
/// keep it Python-derived.
pub fn coerceNumberStr(a: Allocator, val: []const u8) Error![]const u8 {
    const is_float = std.mem.indexOfAny(u8, val, ".eE") != null;
    if (!is_float) return coerceIntStr(a, val);
    const f = std.fmt.parseFloat(f64, val) catch return val;
    return pythonFloatStr(a, f);
}

/// Python's `str(int(val))` for a grammatical integer literal: leading zeros
/// are dropped, the sign is kept, an all-zero mantissa collapses to "0".
/// Anything that is not `["-"] digit {digit}` raises ValueError in Python and
/// returns the string unchanged.
///
/// Deliberately NOT routed through `parseInt(i64, …)`: Python ints are
/// arbitrary-precision, so `int("99999999999999999999")` is fine while an i64
/// would overflow and silently fall back to the unparsed string.
fn coerceIntStr(a: Allocator, val: []const u8) Error![]const u8 {
    var i: usize = 0;
    const neg = val.len > 0 and val[0] == '-';
    if (neg) i = 1;
    if (i >= val.len) return val; // "" or "-": ValueError -> unchanged
    for (val[i..]) |c| {
        if (!std.ascii.isDigit(c)) return val; // ValueError -> unchanged
    }
    // Strip leading zeros, keeping at least one digit.
    var start = i;
    while (start + 1 < val.len and val[start] == '0') start += 1;
    const digits = val[start..];
    // Python: str(int("-000")) == "0" — there is no negative zero for ints.
    if (digits.len == 1 and digits[0] == '0') return "0";
    if (!neg) return digits;
    if (start == i) return val; // sign already contiguous, nothing stripped
    return std.mem.concat(a, u8, &.{ "-", digits });
}

/// Python's `repr(float)` / `str(float)` (identical since 3.1): the shortest
/// digit string that round-trips, rendered with CPython's `format_float_short`
/// presentation rules (Python/pystrtod.c, mode 'r'):
///
///   * scientific iff the decimal exponent `e` (value = d.ddd x 10^e) is
///     `e < -4 or e >= 16`;
///   * the exponent is always signed and zero-padded to at least 2 digits
///     (`1e+16`, `1e-05`) — Zig's `{e}` emits `1e16` / `1e-5`;
///   * fixed notation gets a forced `.0` when it would otherwise look like an
///     integer (`2.0`, `-0.0`, `1000000000000000.0`) — Zig's `{d}` emits `2`;
///   * `-0.0` keeps its sign.
///
/// Zig's `{e}` already yields the shortest round-trip digits (same Ryu-class
/// algorithm as CPython's David Gay / short-repr path), so this parses that and
/// re-presents it. `{d}` is NOT usable: it never switches to scientific and
/// never forces `.0`.
fn pythonFloatStr(a: Allocator, f: f64) Error![]const u8 {
    var buf: [64]u8 = undefined;
    // Shortest round-trip, always scientific: "[-]d[.ddd]e[-]X".
    const sci = std.fmt.bufPrint(&buf, "{e}", .{f}) catch unreachable;

    var rest = sci;
    const neg = rest.len > 0 and rest[0] == '-';
    if (neg) rest = rest[1..];

    const epos = std.mem.indexOfScalar(u8, rest, 'e') orelse return std.fmt.allocPrint(a, "{s}", .{sci});
    const mant = rest[0..epos];
    const exp = std.fmt.parseInt(i32, rest[epos + 1 ..], 10) catch return std.fmt.allocPrint(a, "{s}", .{sci});

    // Mantissa digits with the point removed: "1.23456" -> "123456".
    var digits_buf: [32]u8 = undefined;
    var n: usize = 0;
    for (mant) |c| {
        if (c == '.') continue;
        digits_buf[n] = c;
        n += 1;
    }
    const digits = digits_buf[0..n];

    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (neg) try out.append(a, '-');

    if (exp < -4 or exp >= 16) {
        // Scientific: d[.ddd] e (sign) (>=2 exponent digits). No forced ".0".
        try out.append(a, digits[0]);
        if (digits.len > 1) {
            try out.append(a, '.');
            try out.appendSlice(a, digits[1..]);
        }
        try out.append(a, 'e');
        try out.append(a, if (exp < 0) '-' else '+');
        // f64's decimal exponent is at most 3 digits (|exp| <= 324).
        const mag: u32 = @intCast(if (exp < 0) -@as(i64, exp) else @as(i64, exp));
        var ebuf: [8]u8 = undefined;
        try out.appendSlice(a, std.fmt.bufPrint(&ebuf, "{d:0>2}", .{mag}) catch unreachable);
        return out.toOwnedSlice(a);
    }

    if (exp >= 0) {
        const int_len: usize = @intCast(exp + 1);
        if (int_len >= digits.len) {
            try out.appendSlice(a, digits);
            try out.appendNTimes(a, '0', int_len - digits.len);
            try out.appendSlice(a, ".0"); // forced .0
        } else {
            try out.appendSlice(a, digits[0..int_len]);
            try out.append(a, '.');
            try out.appendSlice(a, digits[int_len..]);
        }
    } else {
        // -4 <= exp < 0: "0." ++ (-exp-1) zeros ++ digits
        try out.appendSlice(a, "0.");
        try out.appendNTimes(a, '0', @intCast(-exp - 1));
        try out.appendSlice(a, digits);
    }
    return out.toOwnedSlice(a);
}

/// lower.py `emit_docs_runtime` (0012 §5.1). Section order is fixed; ordering
/// within each section is source order of the decls. No timestamps.
pub fn emitDocsRuntime(a: Allocator, g: *const graphmod.Graph, source_file: []const u8) Error!Emitted {
    const rv_opt = try runtimeView(a, g);
    const rv = rv_opt orelse return .{ .files = &.{}, .entries = &.{} };
    const runtime = rv.runtime;
    const sf = source_file;
    const rt_name = runtime.name;
    const systems = try strList(a, getProp(runtime.props, "systems"));

    var L = Lines.init(a);
    try L.addFmt("<!-- {s} -->", .{try header(a, sf, try std.fmt.allocPrint(a, "runtime {s}", .{rt_name}))});
    try L.add("");
    try L.addFmt("# Runtime: {s}", .{rt_name});
    try L.add("");
    try L.addFmt("Generated from `{s}`. This document is a rendering of the", .{headerFile(sf)});
    try L.addFmt("`runtime {s}` declaration — see", .{rt_name});
    try L.add("[`docs/language/0012-lowering.md`](../../../../docs/language/0012-lowering.md)");
    try L.add("§5.1. Do not edit; regenerate from source.");
    try L.add("");
    {
        var coded: std.ArrayListUnmanaged([]const u8) = .empty;
        for (systems) |s| try coded.append(a, try mdCode(a, s));
        try L.addFmt("- **Systems:** {s}", .{try std.mem.join(a, ", ", coded.items)});
    }
    try L.add("");

    // 2. Indexes
    try L.add("## Indexes");
    try L.add("");
    try L.add("| Index | Source(s) | Normalize / Chunk | Trust | Emit |");
    try L.add("|-------|-----------|-------------------|-------|------|");
    for (rv.indexes) |idx| {
        const normalize = refOf(getProp(idx.props, "normalize"));
        // Python: `_md_code(normalize) if normalize else "—"` — an EMPTY
        // string is falsy too, so it also yields the em-dash.
        const norm_cell = if (normalize != null and normalize.?.len > 0)
            try mdCode(a, normalize.?)
        else
            "—";
        var trust_cell: []const u8 = "—";
        if (indexIsPinned(idx)) {
            const rec = try recordEntries(a, getProp(idx.props, "trust"));
            trust_cell = try std.fmt.allocPrint(a, "`pinned` (commit `{s}`)", .{optStr(rec.get("commit"))});
        }
        const targets = try indexEmitTargets(a, idx);
        var emit_cell: []const u8 = "—";
        if (targets.len > 0) {
            var coded: std.ArrayListUnmanaged([]const u8) = .empty;
            for (targets) |t| try coded.append(a, try mdCode(a, t));
            emit_cell = try std.mem.join(a, ", ", coded.items);
        }
        try L.addFmt("| {s} | {s} | {s} | {s} | {s} |", .{
            try mdCode(a, idx.name),
            try indexSourceRender(a, idx),
            norm_cell,
            trust_cell,
            emit_cell,
        });
    }
    try L.add("");

    // 3. Streams
    try L.add("## Streams");
    try L.add("");
    try L.add("| Stream | Source | Type | Retention / FPS |");
    try L.add("|--------|--------|------|-----------------|");
    for (rv.streams) |st| {
        const source = refOf(getProp(st.props, "source"));
        const typ = refOf(getProp(st.props, "type"));
        const retention = litOf(getProp(st.props, "retention"));
        const fps = litOf(getProp(st.props, "fps"));
        const rf_cell: []const u8 = if (retention) |r|
            try std.fmt.allocPrint(a, "retention `{s}`", .{r})
        else if (fps) |f|
            try std.fmt.allocPrint(a, "fps `{s}`", .{f})
        else
            "—";
        try L.addFmt("| {s} | {s} | {s} | {s} |", .{
            try mdCode(a, st.name), try mdCodeOpt(a, source), try mdCodeOpt(a, typ), rf_cell,
        });
    }
    try L.add("");

    // 4. Fibers
    try L.add("## Fibers");
    try L.add("");
    try L.add("| Fiber | Engine | Input | Output | Policy |");
    try L.add("|-------|--------|-------|--------|--------|");
    for (rv.fibers) |fib| {
        const eng = fiberEngineName(fib);
        const inp = refOf(getProp(fib.props, "input"));
        const out = refOf(getProp(fib.props, "output"));
        try L.addFmt("| {s} | {s} | {s} | {s} | {s} |", .{
            try mdCode(a, fib.name),
            try mdCodeOpt(a, eng),
            try mdCodeOpt(a, inp),
            try mdCodeOpt(a, out),
            try renderPolicy(a, fib),
        });
    }
    try L.add("");

    // 5. Surfaces
    try L.add("## Surfaces");
    try L.add("");
    try L.add("| Surface | Mode | FPS | Input | Views |");
    try L.add("|---------|------|-----|-------|-------|");
    for (rv.surfaces) |surf| {
        const mode = refOf(getProp(surf.props, "mode"));
        const fps = litOf(getProp(surf.props, "fps"));
        const inputs_cell = try renderRefList(a, getProp(surf.props, "input"));
        const views = try strList(a, getProp(surf.props, "views"));
        var coded: std.ArrayListUnmanaged([]const u8) = .empty;
        for (views) |v| try coded.append(a, try mdCode(a, v));
        try L.addFmt("| {s} | {s} | {s} | {s} | {s} |", .{
            try mdCode(a, surf.name),
            try mdCodeOpt(a, mode),
            try mdCodeOpt(a, fps),
            inputs_cell,
            try std.mem.join(a, ", ", coded.items),
        });
    }
    try L.add("");

    // 6. Parallel groups
    try L.add("## Parallel groups");
    try L.add("");
    try L.add("| Group | Fibers | Strategy | Supervisor |");
    try L.add("|-------|--------|----------|------------|");
    for (rv.parallels) |par| {
        const members = try renderRefList(a, getProp(par.props, "fibers"));
        const strategy = litOf(getProp(par.props, "strategy"));
        const supervisor = refOf(getProp(par.props, "supervisor"));
        try L.addFmt("| {s} | {s} | {s} | {s} |", .{
            try mdCode(a, par.name), members, try mdCodeOpt(a, strategy), try mdCodeOpt(a, supervisor),
        });
    }
    try L.add("");

    // 7. Capability grants — declared principal grant-sets per `mesh`, else the
    //    sparse operator-field case (no mesh/capability decl).
    try L.add("## Capability grants");
    try L.add("");
    if (rv.meshes.len > 0) {
        try L.add("Declared principal grant-sets (0011 §4.4, 0012 §5.1), attenuated per `mesh`.");
        try L.add("Read-only principals cannot acquire write/publish grants they were not given:");
        try L.add("");
        for (rv.meshes) |m| {
            try L.addFmt("### mesh `{s}`", .{m.name});
            try L.add("");
            try L.add("| Principal | Role | Capabilities |");
            try L.add("|-----------|------|--------------|");
            const mesh_children = try childrenOf(a, g, m.id);
            for (try byKind(a, mesh_children, "node")) |nd| {
                const role = litOf(getProp(nd.props, "role"));
                const role_cell: []const u8 = if (role) |r| try mdCode(a, r) else "—";
                const caps = try renderRefList(a, getProp(nd.props, "capabilities"));
                // Python: `_render_ref_list(...) or "—"` — an empty string is
                // falsy, so no capabilities renders the em-dash.
                const caps_cell: []const u8 = if (caps.len > 0) caps else "—";
                try L.addFmt("| {s} | {s} | {s} |", .{ try mdCode(a, nd.name), role_cell, caps_cell });
            }
            try L.add("");
        }
        try L.add("The implied daemon-channel uses follow from the stream sources:");
    } else {
        try L.add("No `mesh` or `capability` declarations in this runtime, so there are no declared");
        try L.add("principal grant-sets (0012 §5.1). The implied daemon-channel uses follow from the");
        try L.add("stream sources:");
    }
    try L.add("");
    try L.add("| Principal / consumer | Used channel | Implied membrane |");
    try L.add("|----------------------|--------------|------------------|");
    for (rv.streams) |st| {
        const source = refOf(getProp(st.props, "source"));
        try L.addFmt("| {s} | {s} | {s} |", .{
            try std.fmt.allocPrint(a, "`stream {s}`", .{st.name}),
            try mdCodeOpt(a, source),
            impliedMembrane(source),
        });
    }
    for (rv.fibers) |fib| {
        const out = refOf(getProp(fib.props, "output")) orelse continue;
        if (!std.mem.startsWith(u8, out, "artifacts.")) continue;
        try L.addFmt("| {s} | artifact capture | `filesystem` (fs-snapshotd) |", .{
            try std.fmt.allocPrint(a, "`fiber {s}` (`output = {s}`)", .{ fib.name, out }),
        });
    }
    try L.add("");
    try L.add("> Membranes per [`docs/context/PROJECT_CONTEXT.md`](../../../../docs/context/PROJECT_CONTEXT.md)");
    try L.add("> and the daemon roster in [`docs/runtime/README.md`](../../../../docs/runtime/README.md).");
    try L.add("> eBPF policy manifests / OTel config / systemd units / surface launcher are");
    try L.add("> deferred targets (0012 §7).");

    const text = try L.text();
    const files = try a.alloc(File, 1);
    files[0] = .{ .path = "gen/RUNTIME.md", .content = text };

    // provenance entries: header (runtime) then each section node, source order.
    var entries: std.ArrayListUnmanaged(ProvEntry) = .empty;
    try entries.append(a, .{
        .artifact = "gen/RUNTIME.md",
        .region = "header",
        .source_file = sf,
        .decl = try std.fmt.allocPrint(a, "runtime {s}", .{rt_name}),
        .span = runtime.provenance.?.span,
        .emitter = "docs.runtime",
        .inputs_projection = try nodeProjection(a, runtime),
    });
    const Section = struct { nodes: []graphmod.GraphNode, region: []const u8, kind: []const u8 };
    const sections = [_]Section{
        .{ .nodes = rv.indexes, .region = "indexes/", .kind = "index" },
        .{ .nodes = rv.streams, .region = "streams/", .kind = "stream" },
        .{ .nodes = rv.fibers, .region = "fibers/", .kind = "fiber" },
        .{ .nodes = rv.surfaces, .region = "surfaces/", .kind = "surface" },
        .{ .nodes = rv.parallels, .region = "parallel/", .kind = "parallel" },
        .{ .nodes = rv.meshes, .region = "meshes/", .kind = "mesh" },
    };
    for (sections) |sec| {
        for (sec.nodes) |n| {
            try entries.append(a, .{
                .artifact = "gen/RUNTIME.md",
                .region = try std.mem.concat(a, u8, &.{ sec.region, n.name }),
                .source_file = sf,
                .decl = try std.fmt.allocPrint(a, "{s} {s}", .{ sec.kind, n.name }),
                .span = n.provenance.?.span,
                .emitter = "docs.runtime",
                .inputs_projection = try nodeProjection(a, n),
            });
        }
    }
    return .{ .files = files, .entries = try entries.toOwnedSlice(a) };
}

// --------------------------------------------------------------------------- //
// Emitter: zig.daemoncfg (per fiber) — gen/zig/<fiber>.json.
// --------------------------------------------------------------------------- //

/// A value in a Zig daemon config (0012 §5.2). Python builds real
/// int/float/bool/str/list objects and renders them with `json.dumps`; this
/// mirrors that, with two deliberate choices:
///
///   * `raw` carries a PRE-RENDERED number. `json.dumps(n) == str(n)` for both
///     int and float in Python 3, so `coerceNumberStr` — which already
///     reproduces `str(_coerce_number(v))` exactly — IS the JSON rendering.
///     This sidesteps the whole precision trap: Python ints are
///     arbitrary-precision and would not survive an i64 round-trip, and floats
///     need CPython's repr presentation rather than Zig's `{d}`.
///   * `object` is ORDERED (Python's `_Ordered`): §5.2 key order is the fixed
///     schema order, NOT sorted.
const ZigVal = union(enum) {
    raw: []const u8,
    string: []const u8,
    boolean: bool,
    none,
    array: []const ZigVal,
    /// A Python `_Ordered`: rendered MULTI-LINE at a 2-space indent.
    object: []const ZigPair,
    /// A plain Python `dict` (NOT `_Ordered`). `_emit_zig_value` has no dict
    /// branch, so it falls through to `json.dumps(val, ensure_ascii=False)` —
    /// ONE LINE, DEFAULT separators (`{"a": 1}`, not `{"a":1}`), insertion
    /// order. This is what `emit_trust_config` builds: its trusts/quorums/
    /// probes are plain dicts inside a list, so `gen/trust.json` renders each
    /// entry inline. Getting this wrong yields a valid-but-wrong pretty tree.
    plain_object: []const ZigPair,
    /// A props subtree that `_scalar_prop` returned unchanged (e.g. a nested
    /// `record`). Same `json.dumps` default-separator fall-through.
    passthrough: json.Value,
};

const ZigPair = struct { key: []const u8, val: ZigVal };

/// lower.py `_scalar_prop`, as a `ZigVal` (the JSON-valued projection). The
/// string-rendering sibling used by docs.runtime is `scalarPropStr`.
fn scalarPropVal(a: Allocator, v: json.Value) Error!ZigVal {
    switch (v) {
        .bool => |b| return .{ .boolean = b }, // `isinstance(raw, bool)`
        .array => |arr| {
            const out = try a.alloc(ZigVal, arr.len);
            for (arr, 0..) |x, i| out[i] = try scalarPropVal(a, x);
            return .{ .array = out };
        },
        else => {},
    }
    if (getProp(v, "lit")) |kind| {
        const k = switch (kind) {
            .string => |s| s,
            else => "",
        };
        const value = getProp(v, "value") orelse return .none; // raw.get("value") -> None
        const val = switch (value) {
            .string => |s| s,
            else => return .{ .passthrough = value },
        };
        if (std.mem.eql(u8, k, "number")) return .{ .raw = try coerceNumberStr(a, val) };
        if (std.mem.eql(u8, k, "bool") or std.mem.eql(u8, k, "boolean")) {
            return .{ .boolean = std.mem.eql(u8, val, "true") };
        }
        return .{ .string = val };
    }
    if (refOf(v)) |r| return .{ .string = r };
    // Python returns `raw` unchanged -> json.dumps of the props subtree.
    return .{ .passthrough = v };
}

/// `json.dumps(v, ensure_ascii=False)` with Python's DEFAULT separators
/// (`", "` / `": "`), preserving insertion order. `writeCanonical` is the
/// COMPACT form, so it cannot be reused here.
fn jsonDumpsDefault(a: Allocator, v: json.Value, out: *std.ArrayListUnmanaged(u8)) Error!void {
    switch (v) {
        .object => |obj| {
            try out.append(a, '{');
            for (obj, 0..) |e, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try out.appendSlice(a, try jsonScalar(a, .{ .string = e.key }));
                try out.appendSlice(a, ": ");
                try jsonDumpsDefault(a, e.value, out);
            }
            try out.append(a, '}');
        },
        .array => |arr| {
            try out.append(a, '[');
            for (arr, 0..) |x, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try jsonDumpsDefault(a, x, out);
            }
            try out.append(a, ']');
        },
        else => try out.appendSlice(a, try jsonScalar(a, v)),
    }
}

/// lower.py `_emit_zig_value`: 2-space indent, one member per line for
/// objects, one-LINE arrays for scalar lists (`["png", "webp"]`), `": "` after
/// keys, line-trailing commas between members.
fn emitZigValue(a: Allocator, val: ZigVal, level: usize, out: *std.ArrayListUnmanaged(u8)) Error!void {
    switch (val) {
        .object => |pairs| {
            if (pairs.len == 0) {
                try out.appendSlice(a, "{}");
                return;
            }
            const pad = try repeatStr(a, "  ", level);
            const pad_in = try repeatStr(a, "  ", level + 1);
            try out.appendSlice(a, "{\n");
            for (pairs, 0..) |p, i| {
                try out.appendSlice(a, pad_in);
                try out.appendSlice(a, try jsonScalar(a, .{ .string = p.key }));
                try out.appendSlice(a, ": ");
                try emitZigValue(a, p.val, level + 1, out);
                if (i < pairs.len - 1) try out.append(a, ',');
                try out.append(a, '\n');
            }
            try out.appendSlice(a, pad);
            try out.append(a, '}');
        },
        .array => |arr| {
            try out.append(a, '[');
            for (arr, 0..) |x, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try emitZigValue(a, x, level + 1, out);
            }
            try out.append(a, ']');
        },
        .raw => |s| try out.appendSlice(a, s),
        .string => |s| try out.appendSlice(a, try jsonScalar(a, .{ .string = s })),
        .boolean => |b| try out.appendSlice(a, if (b) "true" else "false"),
        .none => try out.appendSlice(a, "null"),
        .plain_object => try emitZigValueDumps(a, val, out),
        .passthrough => |pv| try jsonDumpsDefault(a, pv, out),
    }
}

/// `json.dumps(val, ensure_ascii=False)` over a ZigVal: one line, DEFAULT
/// separators, insertion order. The renderer `_emit_zig_value` falls back to
/// for any value that is not an `_Ordered` or a list.
fn emitZigValueDumps(a: Allocator, val: ZigVal, out: *std.ArrayListUnmanaged(u8)) Error!void {
    switch (val) {
        .plain_object, .object => |pairs| {
            try out.append(a, '{');
            for (pairs, 0..) |p, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try out.appendSlice(a, try jsonScalar(a, .{ .string = p.key }));
                try out.appendSlice(a, ": ");
                try emitZigValueDumps(a, p.val, out);
            }
            try out.append(a, '}');
        },
        .array => |arr| {
            try out.append(a, '[');
            for (arr, 0..) |x, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try emitZigValueDumps(a, x, out);
            }
            try out.append(a, ']');
        },
        .raw => |s| try out.appendSlice(a, s),
        .string => |s| try out.appendSlice(a, try jsonScalar(a, .{ .string = s })),
        .boolean => |b| try out.appendSlice(a, if (b) "true" else "false"),
        .none => try out.appendSlice(a, "null"),
        .passthrough => |pv| try jsonDumpsDefault(a, pv, out),
    }
}

/// lower.py `_emit_zig_json`: the §5.2 document body + a trailing newline.
fn emitZigJson(a: Allocator, val: ZigVal) Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try emitZigValue(a, val, 0, &out);
    try out.append(a, '\n');
    return out.toOwnedSlice(a);
}

/// lower.py `_stream_for_fiber_input`: follow `fiber.input` to its in-runtime
/// stream node (if any). The addressed stream name is the ref's LAST segment
/// (`input = stream.screenrec` -> `screenrec`).
fn streamForFiberInput(rv: RuntimeView, fiber: graphmod.GraphNode) ?graphmod.GraphNode {
    const inp = refOf(getProp(fiber.props, "input")) orelse return null;
    var target_name = inp;
    if (std.mem.lastIndexOfScalar(u8, inp, '.')) |i| target_name = inp[i + 1 ..];
    for (rv.streams) |st| {
        if (std.mem.eql(u8, st.name, target_name)) return st;
    }
    return null;
}

/// lower.py `_zig_config_for_fiber`: the ordered config object for a fiber
/// (0012 §5.2 table row order), with absent optionals OMITTED (never null).
fn zigConfigForFiber(a: Allocator, rv: RuntimeView, fib: graphmod.GraphNode, sf: []const u8) Error!ZigVal {
    var pairs: std.ArrayListUnmanaged(ZigPair) = .empty;
    try pairs.append(a, .{
        .key = "_generated",
        .val = .{ .string = try header(a, sf, try std.fmt.allocPrint(a, "fiber {s}", .{fib.name})) },
    });
    if (fiberEngineName(fib)) |eng| {
        try pairs.append(a, .{ .key = "engine", .val = .{ .string = eng } });
        try pairs.append(a, .{
            .key = "engine_package",
            .val = .{ .string = try std.fmt.allocPrint(a, "packages.{s}", .{eng}) },
        });
    }

    // input { stream, source, type, fps }
    var input_pairs: std.ArrayListUnmanaged(ZigPair) = .empty;
    if (streamForFiberInput(rv, fib)) |st| {
        try input_pairs.append(a, .{ .key = "stream", .val = .{ .string = st.name } });
        if (refOf(getProp(st.props, "source"))) |s| {
            try input_pairs.append(a, .{ .key = "source", .val = .{ .string = s } });
        }
        if (refOf(getProp(st.props, "type"))) |t| {
            try input_pairs.append(a, .{ .key = "type", .val = .{ .string = t } });
        }
        if (litOf(getProp(st.props, "fps"))) |f| {
            // `_coerce_number(st_fps)` -> a JSON NUMBER, not a string.
            try input_pairs.append(a, .{ .key = "fps", .val = .{ .raw = try coerceNumberStr(a, f) } });
        }
    }
    if (input_pairs.items.len > 0) {
        try pairs.append(a, .{ .key = "input", .val = .{ .object = try input_pairs.toOwnedSlice(a) } });
    }

    // output { target }
    if (refOf(getProp(fib.props, "output"))) |out_ref| {
        const one = try a.alloc(ZigPair, 1);
        one[0] = .{ .key = "target", .val = .{ .string = out_ref } };
        try pairs.append(a, .{ .key = "output", .val = .{ .object = one } });
    }

    // policy { … } — source order, from the enrichGraph-attached sub-block.
    const policy_pairs = try zigPolicyPairs(a, fib);
    if (policy_pairs.len > 0) {
        try pairs.append(a, .{ .key = "policy", .val = .{ .object = policy_pairs } });
    }

    // budget (optional) — omitted entirely when absent.
    if (getProp(fib.props, "budget")) |budget| {
        try pairs.append(a, .{ .key = "budget", .val = try scalarPropVal(a, budget) });
    }

    // observe (default false)
    const observe: ZigVal = if (getProp(fib.props, "observe")) |o|
        try scalarPropVal(a, o)
    else
        .{ .boolean = false };
    try pairs.append(a, .{ .key = "observe", .val = observe });

    return .{ .object = try pairs.toOwnedSlice(a) };
}

/// lower.py `_zig_policy_pairs` / `_fiber_policy_fields`: the fiber's
/// `policy { … }` record projected in SOURCE order, which is the §5.2 emission
/// order.
fn zigPolicyPairs(a: Allocator, fib: graphmod.GraphNode) Error![]const ZigPair {
    var pairs: std.ArrayListUnmanaged(ZigPair) = .empty;
    const arr: []const json.Value = blk: {
        const pol = getProp(fib.props, "policy") orelse break :blk &.{};
        const rec = getProp(pol, "record") orelse break :blk &.{};
        switch (rec) {
            .array => |x| break :blk x,
            else => break :blk &.{},
        }
    };
    for (arr) |e| {
        const assign = getProp(e, "assign") orelse continue;
        const name = switch (assign) {
            .string => |s| s,
            else => continue,
        };
        const raw = getProp(e, "value") orelse json.Value{ .null = {} };
        try pairs.append(a, .{ .key = name, .val = try scalarPropVal(a, raw) });
    }
    return pairs.toOwnedSlice(a);
}

/// lower.py `emit_zig_daemoncfg`: one `gen/zig/<fiber>.json` per fiber
/// (0012 §5.2). Key order is the fixed schema order (NOT sorted);
/// `_generated` is always first; an absent optional is omitted, never null.
pub fn emitZigDaemoncfg(a: Allocator, g: *const graphmod.Graph, source_file: []const u8, nodes: []const graphmod.GraphNode) Error!Emitted {
    const rv_opt = try runtimeView(a, g);
    const rv = rv_opt orelse return .{ .files = &.{}, .entries = &.{} };
    const sf = source_file;
    var files: std.ArrayListUnmanaged(File) = .empty;
    var entries: std.ArrayListUnmanaged(ProvEntry) = .empty;
    for (nodes) |fib| {
        const cfg = try zigConfigForFiber(a, rv, fib, sf);
        const text = try emitZigJson(a, cfg);
        const path = try std.fmt.allocPrint(a, "gen/zig/{s}.json", .{fib.name});
        try files.append(a, .{ .path = path, .content = text });
        try entries.append(a, .{
            .artifact = path,
            .region = null,
            .source_file = sf,
            .decl = try std.fmt.allocPrint(a, "fiber {s}", .{fib.name}),
            .span = fib.provenance.?.span,
            .emitter = "zig.daemoncfg",
            .inputs_projection = try nodeProjection(a, fib),
        });
    }
    return .{ .files = try files.toOwnedSlice(a), .entries = try entries.toOwnedSlice(a) };
}

// --------------------------------------------------------------------------- //
// Emitter: catalog.jsonl (per index w/ emit ∋ catalog.jsonl)
//                                              — gen/catalog/<index>.jsonl.
// --------------------------------------------------------------------------- //

/// lower.py `_CATALOG_PLACEHOLDER_ROWS` (0012 §5.3b). The REAL rows are
/// produced by the CrabCC index derivation at build time over the pinned
/// sources; lowering does NOT fetch or index (§2.3). For the fixture set,
/// lowering emits the header plus these DISCLOSED placeholder rows, derived
/// from the source list's github "owner/repo" slug — never invented from
/// network content. Keyed by index name; an index with no entry emits the
/// header line only.
const CatalogRow = struct { owner_repo: []const u8, path: []const u8, text: []const u8 };

fn catalogPlaceholderRows(index_name: []const u8) []const CatalogRow {
    if (std.mem.eql(u8, index_name, "zigCorpus")) return &.{
        .{
            .owner_repo = "Sobeston/zig.guide",
            .path = "chapter-1/hello-world.md",
            .text = "# Hello World\n\nCreate a file `hello.zig` and run it with `zig run hello.zig`.",
        },
        .{
            .owner_repo = "zigimg/zigimg",
            .path = "README.md",
            .text = "# zigimg\n\nZig library for reading and writing images in a variety of formats.",
        },
    };
    return &.{};
}

/// lower.py `_catalog_row_id`: `<repo-slug>#NNNN`. The slug is the segment
/// after the LAST '/' (`rsplit("/", 1)[-1]`) — note this is NOT
/// `_nix_source_slug`: no `.`/`_` normalization, so `Sobeston/zig.guide`
/// yields `zig.guide#0001`, dot intact.
fn catalogRowId(a: Allocator, owner_repo: []const u8, n: usize) Error![]const u8 {
    var repo = owner_repo;
    if (std.mem.lastIndexOfScalar(u8, owner_repo, '/')) |i| repo = owner_repo[i + 1 ..];
    return std.fmt.allocPrint(a, "{s}#{d:0>4}", .{ repo, n });
}

/// lower.py `emit_catalog_jsonl` (0012 §5.3b). Line 1 is the `_generated`
/// header object (so the file stays valid JSONL); subsequent lines are one
/// compact JSON object per indexed item. `json.dumps(separators=(",",":"),
/// ensure_ascii=False)` IS `writeCanonical`, and key order is insertion order
/// (id, source, path, chunk, text) — which writeCanonical preserves.
pub fn emitCatalogJsonl(a: Allocator, source_file: []const u8, nodes: []const graphmod.GraphNode) Error!Emitted {
    const sf = source_file;
    var files: std.ArrayListUnmanaged(File) = .empty;
    var entries: std.ArrayListUnmanaged(ProvEntry) = .empty;
    for (nodes) |idx| {
        var L = Lines.init(a);
        {
            const hobj = try a.alloc(json.Value.Entry, 1);
            hobj[0] = .{
                .key = "_generated",
                .value = .{ .string = try header(a, sf, try std.fmt.allocPrint(a, "index {s}", .{idx.name})) },
            };
            try L.add(try jsonScalar(a, .{ .object = hobj }));
        }
        // `per_repo` counts rows PER REPO SLUG (not per owner/repo), so two
        // sources sharing a slug continue one another's numbering.
        var repo_keys: std.ArrayListUnmanaged([]const u8) = .empty;
        var repo_counts: std.ArrayListUnmanaged(usize) = .empty;
        for (catalogPlaceholderRows(idx.name)) |row| {
            var repo = row.owner_repo;
            if (std.mem.lastIndexOfScalar(u8, row.owner_repo, '/')) |i| repo = row.owner_repo[i + 1 ..];
            var n: usize = 1;
            var found = false;
            for (repo_keys.items, 0..) |k, i| {
                if (std.mem.eql(u8, k, repo)) {
                    repo_counts.items[i] += 1;
                    n = repo_counts.items[i];
                    found = true;
                    break;
                }
            }
            if (!found) {
                try repo_keys.append(a, repo);
                try repo_counts.append(a, 1);
            }
            const obj = try a.alloc(json.Value.Entry, 5);
            obj[0] = .{ .key = "id", .value = .{ .string = try catalogRowId(a, row.owner_repo, n) } };
            obj[1] = .{ .key = "source", .value = .{ .string = try std.fmt.allocPrint(a, "github:{s}", .{row.owner_repo}) } };
            obj[2] = .{ .key = "path", .value = .{ .string = row.path } };
            obj[3] = .{ .key = "chunk", .value = .{ .int = 0 } };
            obj[4] = .{ .key = "text", .value = .{ .string = row.text } };
            try L.add(try jsonScalar(a, .{ .object = obj }));
        }
        const path = try std.fmt.allocPrint(a, "gen/catalog/{s}.jsonl", .{idx.name});
        try files.append(a, .{ .path = path, .content = try L.text() });
        try entries.append(a, .{
            .artifact = path,
            .region = null,
            .source_file = sf,
            .decl = try std.fmt.allocPrint(a, "index {s}", .{idx.name}),
            .span = idx.provenance.?.span,
            .emitter = "catalog.jsonl",
            .inputs_projection = try nodeProjection(a, idx),
        });
    }
    return .{ .files = try files.toOwnedSlice(a), .entries = try entries.toOwnedSlice(a) };
}

// --------------------------------------------------------------------------- //
// Emitter: otp.supervision (per `parallel … supervisor = otp`) — gen/otp/*.erl.
// --------------------------------------------------------------------------- //

/// lower.py `_otp_slug`: a runtime name as a legal Erlang module atom prefix,
/// strictly `[a-z][a-z0-9_]*`. A 'v' is prefixed when the result does not start
/// with a letter (the module name MUST match the filename — an OTP rule).
///
/// Python uses EXPLICIT ASCII ranges, not `str.isalnum()`, precisely because
/// isalnum is Unicode-aware (Arabic-Indic digits pass it) and erlc rejects a
/// non-ASCII module name. Python iterates CODEPOINTS of `name.lower()`, so one
/// non-ASCII character yields exactly one '_'.
///
/// KNOWN NARROW DIVERGENCE (reported, not silently pinned): we decode UTF-8 and
/// map any non-ASCII codepoint to '_' without applying full Unicode lowercasing
/// (Zig's stdlib has no Unicode case table). This matches Python for every
/// ASCII name and for all non-ASCII EXCEPT the handful of codepoints whose
/// lowercase lands inside [a-z0-9] — e.g. U+212A KELVIN SIGN lowercases to 'k'
/// in Python but becomes '_' here. Unreachable from the fixture set; a runtime
/// decl would have to be named with such a character.
pub fn otpSlug(a: Allocator, name: []const u8) Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const view = std.unicode.Utf8View.init(name) catch {
        // Not valid UTF-8: fall back to one '_' per byte (the lexer only
        // produces valid UTF-8, so this is unreachable in practice).
        for (name) |_| try out.append(a, '_');
        return finishOtpSlug(a, try out.toOwnedSlice(a));
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 128) {
            const c = std.ascii.toLower(@intCast(cp));
            try out.append(a, if ((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9')) c else '_');
        } else {
            try out.append(a, '_');
        }
    }
    return finishOtpSlug(a, try out.toOwnedSlice(a));
}

fn finishOtpSlug(a: Allocator, s: []const u8) Error![]const u8 {
    if (s.len == 0 or !(s[0] >= 'a' and s[0] <= 'z')) {
        return std.mem.concat(a, u8, &.{ "v", s });
    }
    return s;
}

const OtpMember = struct { name: []const u8, kind: []const u8, config: ?[]const u8 };

/// lower.py `_otp_members`: the resolved members of a parallel group's `fibers`
/// list, in DECLARED order. Fibers carry their gen/zig config path; surfaces
/// have none (launcher deferred, §7). Members are in-runtime decls
/// (closed-world checked), so unresolved names are simply skipped.
fn otpMembers(a: Allocator, rv: RuntimeView, par: graphmod.GraphNode) Error![]const OtpMember {
    var out: std.ArrayListUnmanaged(OtpMember) = .empty;
    const members = getProp(par.props, "fibers") orelse return out.toOwnedSlice(a);
    const arr = switch (members) {
        .array => |x| x,
        else => return out.toOwnedSlice(a),
    };
    for (arr) |m| {
        const name = refOf(m) orelse continue;
        var matched = false;
        for (rv.fibers) |f| {
            if (std.mem.eql(u8, f.name, name)) {
                try out.append(a, .{
                    .name = name,
                    .kind = "fiber",
                    .config = try std.fmt.allocPrint(a, "gen/zig/{s}.json", .{name}),
                });
                matched = true;
                break;
            }
        }
        if (matched) continue;
        for (rv.surfaces) |s| {
            if (std.mem.eql(u8, s.name, name)) {
                try out.append(a, .{ .name = name, .kind = "surface", .config = null });
                break;
            }
        }
    }
    return out.toOwnedSlice(a);
}

/// lower.py `_OTP_WORKER_BODY`. Note the trailing newline: Python's triple
/// quoted literal ends with one, which is what gives the worker file its final
/// newline (the join adds none).
const otp_worker_body =
    \\-module(vaked_fiber_worker).
    \\-behaviour(gen_server).
    \\
    \\-export([start_link/1]).
    \\-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
    \\
    \\-define(TICK_MS, 5000).
    \\
    \\start_link(#{name := Name} = Args) ->
    \\    gen_server:start_link({local, Name}, ?MODULE, Args, []).
    \\
    \\init(#{name := Name, kind := Kind} = Args) ->
    \\    logger:info("vaked ~p ~p up (placeholder; daemon port pending)",
    \\                [Kind, Name]),
    \\    erlang:send_after(?TICK_MS, self(), tick),
    \\    {ok, Args}.
    \\
    \\handle_call(_Req, _From, State) ->
    \\    {reply, ok, State}.
    \\
    \\handle_cast(_Msg, State) ->
    \\    {noreply, State}.
    \\
    \\handle_info(tick, #{name := Name} = State) ->
    \\    logger:debug("vaked heartbeat ~p", [Name]),
    \\    erlang:send_after(?TICK_MS, self(), tick),
    \\    {noreply, State}.
    \\
;

/// lower.py `emit_otp_supervision` (#19, Track C): one
/// `gen/otp/<runtime_slug>_sup.erl` supervisor (a child spec per member of
/// each `parallel … supervisor = otp` group, in declared order — byte
/// determinism only, NO restart-coupling claim) plus the generic placeholder
/// worker `gen/otp/vaked_fiber_worker.erl`.
///
/// v0 strategy mapping: `"supervised-dag"` (and anything else) lowers to
/// `one_for_one` — downstream consistency is RFC 0004's job.
pub fn emitOtpSupervision(a: Allocator, g: *const graphmod.Graph, source_file: []const u8, nodes: []const graphmod.GraphNode) Error!Emitted {
    const rv_opt = try runtimeView(a, g);
    const rv = rv_opt orelse return .{ .files = &.{}, .entries = &.{} };
    const sf = source_file;
    const rt = rv.runtime;
    const slug = try otpSlug(a, rt.name);
    const rt_decl = try std.fmt.allocPrint(a, "runtime {s}", .{rt.name});

    var child_blocks: std.ArrayListUnmanaged([]const u8) = .empty;
    var entries: std.ArrayListUnmanaged(ProvEntry) = .empty;
    const sup_path = try std.fmt.allocPrint(a, "gen/otp/{s}_sup.erl", .{slug});
    var seen: std.ArrayListUnmanaged([]const u8) = .empty; // OTP rejects duplicate child ids at boot; first wins
    for (nodes) |par| {
        for (try otpMembers(a, rv, par)) |m| {
            if (containsStr(seen.items, m.name)) continue;
            try seen.append(a, m.name);
            const cfg = if (m.config) |c| try std.fmt.allocPrint(a, "\"{s}\"", .{c}) else "none";
            try child_blocks.append(a, try std.fmt.allocPrint(a,
                \\        #{{id => '{s}',
                \\          start => {{vaked_fiber_worker, start_link,
                \\                    [#{{name => '{s}', kind => {s},
                \\                       config => {s}}}]}},
                \\          restart => permanent, shutdown => 5000,
                \\          type => worker,
                \\          modules => [vaked_fiber_worker]}}
            , .{ m.name, m.name, m.kind, cfg }));
        }
        try entries.append(a, .{
            .artifact = sup_path,
            .region = try std.mem.concat(a, u8, &.{ "parallel/", par.name }),
            .source_file = sf,
            .decl = try std.fmt.allocPrint(a, "parallel {s}", .{par.name}),
            .span = par.provenance.?.span,
            .emitter = "otp.supervision",
            .inputs_projection = try nodeProjection(a, par),
        });
    }

    var S = Lines.init(a);
    try S.addFmt("%% {s}", .{try header(a, sf, rt_decl)});
    try S.add("%%");
    try S.add("%% otp.supervision (0012 3.4; Track C #19). v0 strategy: one_for_one -");
    try S.add("%% downstream consistency is RFC 0004's job (stale_dependency pausing);");
    try S.add("%% eager per-chain rest_for_one is the edge-aware follow-up (design");
    try S.add("%% 2026-06-12-otp-supervision-lowering-design.md).");
    try S.addFmt("-module({s}_sup).", .{slug});
    try S.add("-behaviour(supervisor).");
    try S.add("");
    try S.add("-export([start_link/0, init/1]).");
    try S.add("");
    try S.add("start_link() ->");
    try S.add("    supervisor:start_link({local, ?MODULE}, ?MODULE, []).");
    try S.add("");
    try S.add("init([]) ->");
    try S.add("    SupFlags = #{strategy => one_for_one, intensity => 3, period => 10},");
    try S.add("    Children = [");
    // One list element: the child blocks joined by ",\n". With no members this
    // is the empty string, which Python still emits as its own line.
    try S.add(try std.mem.join(a, ",\n", child_blocks.items));
    try S.add("    ],");
    try S.add("    {ok, {SupFlags, Children}}.");
    // Python's list ends with a final "" element, so its "\n".join supplies the
    // document's trailing newline. `Lines.text` appends that newline itself —
    // so the "" element is deliberately NOT added here.
    const sup_text = try S.text();

    var W = Lines.init(a);
    try W.addFmt("%% {s}", .{try header(a, sf, rt_decl)});
    try W.add("%%");
    try W.add("%% Generic placeholder worker: heartbeats until the member's Zig");
    try W.add("%% daemon port replaces it. Deliberately does NOT write eventd (the");
    try W.add("%% canonical-hash byte contract stays with the Python oracle; the");
    try W.add("%% daemon owns the single writer, RFC 0004).");
    // `_OTP_WORKER_BODY` is the join's LAST element and already ends in "\n",
    // so Python's document ends with exactly one newline. `Lines.text` appends
    // its own, so strip the body's to avoid doubling it.
    try W.add(otp_worker_body[0 .. otp_worker_body.len - 1]);
    const worker_text = try W.text();

    const worker_path = "gen/otp/vaked_fiber_worker.erl";
    const files = try a.alloc(File, 2);
    files[0] = .{ .path = sup_path, .content = sup_text };
    files[1] = .{ .path = worker_path, .content = worker_text };
    try entries.append(a, .{
        .artifact = worker_path,
        .region = null,
        .source_file = sf,
        .decl = rt_decl,
        .span = rt.provenance.?.span,
        .emitter = "otp.supervision",
        .inputs_projection = try nodeProjection(a, rt),
    });
    return .{ .files = files, .entries = try entries.toOwnedSlice(a) };
}

// --------------------------------------------------------------------------- //
// NixOS-deployment cohort emitters (#1-#6).
//
// Each lowers a cohort kind to a NixOS-module fragment under gen/ that the
// deferred (§4.3) nixosModules.<runtime> body imports. Shared value
// vocabulary: `Bind` (loopback()/bind()), `secret.X.path`, `hostResource.X.dsn`.
// All gate on presence, so a runtime without them emits nothing (operator-field
// stays byte-identical).
//
// NOTE on numbers: this cohort renders number literals VERBATIM via
// `_nix_literal` (`str(val)` on the stored string) — it does NOT go through
// `_coerce_number`. So `2.0` stays `2.0` and `007` stays `007` here, unlike the
// `_scalar_prop` path used by docs.runtime/zig.daemoncfg. Do not "helpfully"
// route these through coerceNumberStr.
// --------------------------------------------------------------------------- //

/// lower.py `_module_header`: the NixOS-module fragment header.
fn moduleHeader(a: Allocator, L: *Lines, sf: []const u8, decl: []const u8, summary: []const u8) Error!void {
    try L.addFmt("# {s}", .{try header(a, sf, decl)});
    try L.add("#");
    try L.addFmt("# {s}", .{summary});
    try L.add("# NixOS module fragment imported by nixosModules.<runtime> (0012 §4.3).");
}

/// lower.py `_nix_literal`: string→quoted, bool→true/false, number→BARE
/// (verbatim, no `_coerce_number`), other scalars→quoted. Null when `vprop` is
/// not a literal.
fn nixLiteral(a: Allocator, vprop: ?json.Value) Error!?[]const u8 {
    const v = vprop orelse return null;
    const kind_v = getProp(v, "lit") orelse return null;
    const kind = switch (kind_v) {
        .string => |s| s,
        else => "",
    };
    const val = litOf(v); // may be null -> Python renders the text "None"
    if (std.mem.eql(u8, kind, "string")) return try std.fmt.allocPrint(a, "\"{s}\"", .{optStr(val)});
    if (std.mem.eql(u8, kind, "bool")) {
        // Python: `"true" if str(val).lower() == "true" else "false"`
        const s = optStr(val);
        const lowered = try std.ascii.allocLowerString(a, s);
        return if (std.mem.eql(u8, lowered, "true")) "true" else "false";
    }
    if (std.mem.eql(u8, kind, "number")) return optStr(val); // BARE, verbatim
    return try std.fmt.allocPrint(a, "\"{s}\"", .{optStr(val)});
}

const BindParts = struct { addr: []const u8, host_port: []const u8, container_port: ?[]const u8 };

/// lower.py `_bind_parts`: decompose a Bind call (`loopback(...)`/`bind(...)`)
/// into (addr, host_port, container_port); container_port is null for non-OCI
/// forms. Ports are the raw string literals.
fn bindParts(a: Allocator, prop: ?json.Value) Error!?BindParts {
    const call = (try appCall(a, prop)) orelse return null;
    if (std.mem.eql(u8, call.ref, "loopback")) {
        if (call.args.len == 1) return BindParts{ .addr = "127.0.0.1", .host_port = optStr(call.args[0]), .container_port = null };
        if (call.args.len == 2) return BindParts{ .addr = "127.0.0.1", .host_port = optStr(call.args[0]), .container_port = optStr(call.args[1]) };
        return null;
    }
    if (std.mem.eql(u8, call.ref, "bind") and call.args.len == 2) {
        return BindParts{ .addr = optStr(call.args[0]), .host_port = optStr(call.args[1]), .container_port = null };
    }
    return null;
}

/// lower.py `_render_bind`: `host:port` (or OCI `host:hp:cp`).
fn renderBind(a: Allocator, prop: ?json.Value) Error!?[]const u8 {
    const p = (try bindParts(a, prop)) orelse return null;
    if (p.container_port) |cp| return try std.fmt.allocPrint(a, "{s}:{s}:{s}", .{ p.addr, p.host_port, cp });
    return try std.fmt.allocPrint(a, "{s}:{s}", .{ p.addr, p.host_port });
}

/// lower.py `_secret_sops_name`: a `secret` node's `name` field literal.
fn secretSopsName(node: graphmod.GraphNode) ?[]const u8 {
    return litOf(getProp(node.props, "name"));
}

/// lower.py `_host_resource_dsn`: the connection URL `hostResource.X.dsn`
/// lowers to (postgresql today; a fixed per-kind template — §2.4 projection).
fn hostResourceDsn(a: Allocator, node: graphmod.GraphNode) Error!?[]const u8 {
    const kind = litOf(getProp(node.props, "kind")) orelse return null;
    if (!std.mem.eql(u8, kind, "postgresql")) return null;
    const name = litOf(getProp(node.props, "name"));
    return try std.fmt.allocPrint(a, "postgresql:///{s}?host=/run/postgresql", .{optStr(name)});
}

/// lower.py `_accessor_nix`: a 3-part accessor ref (`secret.X.path` /
/// `hostResource.X.dsn`) rendered to Nix, resolving X against the runtime's
/// decls (the checker has already proven X exists).
fn accessorNix(a: Allocator, rv: RuntimeView, ref_dotted: []const u8) Error!?[]const u8 {
    var it = std.mem.splitScalar(u8, ref_dotted, '.');
    var parts: [4][]const u8 = undefined;
    var n: usize = 0;
    while (it.next()) |p| {
        if (n == 4) return null; // more than 3 segments
        parts[n] = p;
        n += 1;
    }
    if (n != 3) return null;
    const head = parts[0];
    const name = parts[1];
    const field = parts[2];
    if (std.mem.eql(u8, head, "secret") and std.mem.eql(u8, field, "path")) {
        // secret.X.path -> a Nix expression referencing config (UNQUOTED).
        for (rv.secrets) |s| {
            if (!std.mem.eql(u8, s.name, name)) continue;
            const key = secretSopsName(s) orelse name;
            return try std.fmt.allocPrint(a, "config.sops.secrets.\"{s}\".path", .{key});
        }
    }
    if (std.mem.eql(u8, head, "hostResource") and std.mem.eql(u8, field, "dsn")) {
        // hostResource.X.dsn -> a string VALUE, so a QUOTED Nix string.
        for (rv.host_resources) |hr| {
            if (!std.mem.eql(u8, hr.name, name)) continue;
            const dsn = (try hostResourceDsn(a, hr)) orelse return null;
            return try std.fmt.allocPrint(a, "\"{s}\"", .{dsn});
        }
    }
    return null;
}

const NamedProp = struct { name: []const u8, value: ?json.Value };

/// lower.py `_record_value_props`: `[(name, value-prop)]` of a config-block
/// record, source order — PRESERVING ref/app values (unlike `_record_entries`,
/// which keeps only literals).
fn recordValueProps(a: Allocator, prop: ?json.Value) Error![]const NamedProp {
    var out: std.ArrayListUnmanaged(NamedProp) = .empty;
    const v = prop orelse return out.toOwnedSlice(a);
    const rec = getProp(v, "record") orelse return out.toOwnedSlice(a);
    const arr = switch (rec) {
        .array => |x| x,
        else => return out.toOwnedSlice(a),
    };
    for (arr) |e| {
        const assign = getProp(e, "assign") orelse continue;
        const name = switch (assign) {
            .string => |s| s,
            else => continue,
        };
        try out.append(a, .{ .name = name, .value = getProp(e, "value") });
    }
    return out.toOwnedSlice(a);
}

/// lower.py `_render_setting`: an accessor ref (secret.X.path /
/// hostResource.X.dsn), else a literal; other refs pass through bare.
fn renderSetting(a: Allocator, rv: RuntimeView, vprop: ?json.Value) Error![]const u8 {
    if (refOf(vprop)) |ref| {
        if (try accessorNix(a, rv, ref)) |acc| return acc;
        return ref;
    }
    if (try nixLiteral(a, vprop)) |lit| return lit;
    return "null";
}

/// lower.py `_SECRET_SOPS_OPTIONS` — fixed emission order.
const secret_sops_options = [_][]const u8{ "owner", "mode" };

/// lower.py `emit_sops_secrets` (#2): one `gen/nixos/sops.nix` declaring every
/// `secret` node's `sops.secrets."<name>"` entry. owner/mode only when present.
pub fn emitSopsSecrets(a: Allocator, source_file: []const u8, nodes: []const graphmod.GraphNode) Error!Emitted {
    if (nodes.len == 0) return .{ .files = &.{}, .entries = &.{} };
    const sf = source_file;
    var L = Lines.init(a);
    try moduleHeader(a, &L, sf, try std.fmt.allocPrint(a, "secret {s}", .{nodes[0].name}), "sops-managed runtime secrets.");
    try L.add("{ config, ... }:");
    try L.add("{");
    for (nodes) |sec| {
        const name = secretSopsName(sec) orelse continue;
        try L.addFmt("  sops.secrets.\"{s}\" = {{", .{name});
        for (secret_sops_options) |opt| {
            if (litOf(getProp(sec.props, opt))) |val| {
                try L.addFmt("    {s} = \"{s}\";", .{ opt, val });
            }
        }
        try L.add("  };");
    }
    try L.add("}");

    const files = try a.alloc(File, 1);
    files[0] = .{ .path = "gen/nixos/sops.nix", .content = try L.text() };
    // NOTE: the entry list covers ALL nodes, including any skipped above for a
    // missing `name` (Python builds it with a separate comprehension).
    const entries = try a.alloc(ProvEntry, nodes.len);
    for (nodes, 0..) |s, i| {
        entries[i] = .{
            .artifact = "gen/nixos/sops.nix",
            .region = try std.fmt.allocPrint(a, "sops.secrets.\"{s}\"", .{secretSopsName(s) orelse s.name}),
            .source_file = sf,
            .decl = try std.fmt.allocPrint(a, "secret {s}", .{s.name}),
            .span = s.provenance.?.span,
            .emitter = "sops.secrets",
            .inputs_projection = try nodeProjection(a, s),
        };
    }
    return .{ .files = files, .entries = entries };
}

/// lower.py `emit_host_resources` (#5): one `gen/nixos/host-resources.nix`
/// provisioning the box's shared DBs.
///
/// !! REPLICATED vakedc BUG (0012 #5) !! The Python filter is
///     `_lit(hr.props.get("create")) is not False`
/// but `_lit` returns the STRING "false" for a `create = false` literal, and
/// `"false" is not False` is ALWAYS True — so `create = false` does NOT exclude
/// the resource, contradicting the emitter's own docstring ("postgresql with
/// create != false"). Reproduced bug-compatibly here BY DEFAULT (verified
/// against the reference); reported rather than fixed. A `create = false`
/// hostResource still lands in ensureDatabases/ensureUsers.
pub fn emitHostResources(a: Allocator, source_file: []const u8, nodes: []const graphmod.GraphNode) Error!Emitted {
    var pg: std.ArrayListUnmanaged(graphmod.GraphNode) = .empty;
    for (nodes) |hr| {
        const kind = litOf(getProp(hr.props, "kind")) orelse continue;
        if (!std.mem.eql(u8, kind, "postgresql")) continue;
        // `_lit(...) is not False` — see the bug note above: always true.
        try pg.append(a, hr);
    }
    if (pg.items.len == 0) return .{ .files = &.{}, .entries = &.{} };
    const sf = source_file;

    var L = Lines.init(a);
    try moduleHeader(a, &L, sf, try std.fmt.allocPrint(a, "hostResource {s}", .{nodes[0].name}), "host-managed resources (shared services.postgresql).");
    try L.add("{ ... }:");
    try L.add("{");
    {
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        for (pg.items) |hr| try names.append(a, optStr(litOf(getProp(hr.props, "name"))));
        try L.addFmt("  services.postgresql.ensureDatabases = [ {s} ];", .{try joinQuoted(a, names.items, " ")});
    }
    try L.add("  services.postgresql.ensureUsers = [");
    for (pg.items) |hr| {
        try L.addFmt("    {{ name = \"{s}\"; ensureDBOwnership = true; }}", .{optStr(litOf(getProp(hr.props, "name")))});
    }
    try L.add("  ];");
    try L.add("}");

    const files = try a.alloc(File, 1);
    files[0] = .{ .path = "gen/nixos/host-resources.nix", .content = try L.text() };
    const entries = try a.alloc(ProvEntry, pg.items.len);
    for (pg.items, 0..) |hr, i| {
        entries[i] = .{
            .artifact = "gen/nixos/host-resources.nix",
            .region = try std.mem.concat(a, u8, &.{ "services.postgresql/", hr.name }),
            .source_file = sf,
            .decl = try std.fmt.allocPrint(a, "hostResource {s}", .{hr.name}),
            .span = hr.provenance.?.span,
            .emitter = "host.resources",
            .inputs_projection = try nodeProjection(a, hr),
        };
    }
    return .{ .files = files, .entries = entries };
}

/// lower.py `emit_nixos_service` (#1): one `gen/nixos/services.nix` declaring
/// every `service` node as `services.<name> = { enable; package;
/// [createPostgresqlDatabase;] settings { [HOSTNAME/PORT;] <options> } }`.
pub fn emitNixosService(a: Allocator, g: *const graphmod.Graph, source_file: []const u8, nodes: []const graphmod.GraphNode) Error!Emitted {
    if (nodes.len == 0) return .{ .files = &.{}, .entries = &.{} };
    const rv = (try runtimeView(a, g)) orelse return .{ .files = &.{}, .entries = &.{} };
    const sf = source_file;

    var L = Lines.init(a);
    try moduleHeader(a, &L, sf, try std.fmt.allocPrint(a, "service {s}", .{nodes[0].name}), "nixpkgs-packaged systemd services.");
    try L.add("{ config, pkgs, ... }:");
    try L.add("{");
    for (nodes) |svc| {
        try L.addFmt("  services.{s} = {{", .{svc.name});
        try L.add("    enable = true;");
        if (refOf(getProp(svc.props, "package"))) |pkg| try L.addFmt("    package = {s};", .{pkg});
        // a hostResource database dependency -> createPostgresqlDatabase shortcut.
        if (refOf(getProp(svc.props, "database")) != null) try L.add("    createPostgresqlDatabase = true;");
        if (litOf(getProp(svc.props, "user"))) |user| try L.addFmt("    user = \"{s}\";", .{user});
        if (litOf(getProp(svc.props, "stateDir"))) |sd| try L.addFmt("    stateDir = \"{s}\";", .{sd});
        // settings: bind (HOSTNAME/PORT) + forwarded options.
        const bind = try bindParts(a, getProp(svc.props, "bind"));
        const opt_entries = try recordValueProps(a, getProp(svc.props, "options"));
        if (bind != null or opt_entries.len > 0) {
            try L.add("    settings = {");
            if (bind) |b| {
                try L.addFmt("      HOSTNAME = \"{s}\";", .{b.addr});
                try L.addFmt("      PORT = {s};", .{b.host_port});
            }
            for (opt_entries) |e| {
                try L.addFmt("      {s} = {s};", .{ e.name, try renderSetting(a, rv, e.value) });
            }
            try L.add("    };");
        }
        try L.add("  };");
    }
    try L.add("}");

    const files = try a.alloc(File, 1);
    files[0] = .{ .path = "gen/nixos/services.nix", .content = try L.text() };
    const entries = try a.alloc(ProvEntry, nodes.len);
    for (nodes, 0..) |svc, i| {
        entries[i] = .{
            .artifact = "gen/nixos/services.nix",
            .region = try std.mem.concat(a, u8, &.{ "services.", svc.name }),
            .source_file = sf,
            .decl = try std.fmt.allocPrint(a, "service {s}", .{svc.name}),
            .span = svc.provenance.?.span,
            .emitter = "nixos.service",
            .inputs_projection = try nodeProjection(a, svc),
        };
    }
    return .{ .files = files, .entries = entries };
}

/// lower.py `_render_upstream`: an ingress `upstream` (Bind | String) — the
/// string literal verbatim, or a Bind rendered host:port.
fn renderUpstream(a: Allocator, prop: ?json.Value) Error!?[]const u8 {
    if (litOf(prop)) |lit| return lit;
    return renderBind(a, prop);
}

/// lower.py `emit_caddy_ingress` (#4): one `gen/caddy/ingress.nix` — a Caddy
/// virtualHost per `ingress` node: `import <tls>` (if any) + `reverse_proxy
/// <upstream>` + raw extraConfig.
pub fn emitCaddyIngress(a: Allocator, source_file: []const u8, nodes: []const graphmod.GraphNode) Error!Emitted {
    if (nodes.len == 0) return .{ .files = &.{}, .entries = &.{} };
    const sf = source_file;

    var L = Lines.init(a);
    try moduleHeader(a, &L, sf, try std.fmt.allocPrint(a, "ingress {s}", .{nodes[0].name}), "Caddy HTTP reverse-proxy virtual hosts.");
    try L.add("{ ... }:");
    try L.add("{");
    for (nodes) |ing| {
        const domain = litOf(getProp(ing.props, "domain"));
        const upstream = try renderUpstream(a, getProp(ing.props, "upstream"));
        const tls = litOf(getProp(ing.props, "tls"));
        const extra = litOf(getProp(ing.props, "extraConfig"));
        try L.addFmt("  services.caddy.virtualHosts.\"{s}\".extraConfig = ''", .{optStr(domain)});
        if (tls) |t| try L.addFmt("    import {s}", .{t});
        try L.addFmt("    reverse_proxy {s}", .{optStr(upstream)});
        if (extra) |e| {
            // Python `str.splitlines()`: splits on \n/\r/\r\n and yields NO
            // trailing empty element for a trailing newline.
            for (try pySplitLines(a, e)) |raw_line| {
                try L.addFmt("    {s}", .{raw_line});
            }
        }
        try L.add("  '';");
    }
    try L.add("}");

    const files = try a.alloc(File, 1);
    files[0] = .{ .path = "gen/caddy/ingress.nix", .content = try L.text() };
    const entries = try a.alloc(ProvEntry, nodes.len);
    for (nodes, 0..) |ing, i| {
        const domain = litOf(getProp(ing.props, "domain"));
        // Python: `_lit(...) or ing.name` — an EMPTY domain is falsy too.
        const region_name = if (domain != null and domain.?.len > 0) domain.? else ing.name;
        entries[i] = .{
            .artifact = "gen/caddy/ingress.nix",
            .region = try std.fmt.allocPrint(a, "virtualHosts.\"{s}\"", .{region_name}),
            .source_file = sf,
            .decl = try std.fmt.allocPrint(a, "ingress {s}", .{ing.name}),
            .span = ing.provenance.?.span,
            .emitter = "caddy.ingress",
            .inputs_projection = try nodeProjection(a, ing),
        };
    }
    return .{ .files = files, .entries = entries };
}

/// Python's `str.splitlines()` for the line kinds a .vaked string literal can
/// carry: splits on \n, \r\n and \r, and does NOT yield a trailing empty
/// element when the text ends with a line break. (Python also splits on a
/// handful of Unicode line boundaries — \v \f \x1c-\x1e     — which
/// a Caddy config block will not contain; noted rather than silently assumed.)
fn pySplitLines(a: Allocator, s: []const u8) Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\n' or s[i] == '\r') {
            try out.append(a, s[start..i]);
            if (s[i] == '\r' and i + 1 < s.len and s[i + 1] == '\n') i += 1;
            i += 1;
            start = i;
        } else i += 1;
    }
    if (start < s.len) try out.append(a, s[start..]);
    return out.toOwnedSlice(a);
}

/// lower.py `_BYTES_SUFFIX_TO_DOCKER`. Iteration order is the dict's insertion
/// order (GB, MB, KB, B) and the loop `if suffix and s.endswith(suffix)` skips
/// the empty "B" key's own entry only via the `if suffix` guard — but "B" IS a
/// real key with value "", so `2B` -> `--memory=2`. Order matters: "GB" is
/// tested before "B", so `2GB` -> `--memory=2g`, not `--memory=2G`.
const bytes_suffix_to_docker = [_]struct { suffix: []const u8, docker: []const u8 }{
    .{ .suffix = "GB", .docker = "g" },
    .{ .suffix = "MB", .docker = "m" },
    .{ .suffix = "KB", .docker = "k" },
    .{ .suffix = "B", .docker = "" },
};

/// lower.py `_render_memory_flag`: `memory = 2GB` -> `--memory=2g`.
fn renderMemoryFlag(a: Allocator, mem_prop: ?json.Value) Error!?[]const u8 {
    const val = litOf(mem_prop) orelse return null;
    const s = std.mem.trim(u8, val, " \t\n\r\x0b\x0c"); // Python str.strip() default
    for (bytes_suffix_to_docker) |m| {
        if (m.suffix.len == 0) continue; // `if suffix and ...`
        if (!std.mem.endsWith(u8, s, m.suffix)) continue;
        const head = std.mem.trim(u8, s[0 .. s.len - m.suffix.len], " \t\n\r\x0b\x0c");
        return try std.fmt.allocPrint(a, "--memory={s}{s}", .{ head, m.docker });
    }
    return try std.fmt.allocPrint(a, "--memory={s}", .{s});
}

/// lower.py `_container_extra_options`: Docker flags in FIXED order —
/// --memory, --network, --health-cmd, then the author's extraOptions verbatim.
fn containerExtraOptions(a: Allocator, c: graphmod.GraphNode) Error![]const []const u8 {
    var opts: std.ArrayListUnmanaged([]const u8) = .empty;
    if (try renderMemoryFlag(a, getProp(c.props, "memory"))) |mem| try opts.append(a, mem);
    if (litOf(getProp(c.props, "network"))) |n| try opts.append(a, try std.fmt.allocPrint(a, "--network={s}", .{n}));
    if (litOf(getProp(c.props, "healthCmd"))) |h| try opts.append(a, try std.fmt.allocPrint(a, "--health-cmd={s}", .{h}));
    try opts.appendSlice(a, try strList(a, getProp(c.props, "extraOptions")));
    return opts.toOwnedSlice(a);
}

/// lower.py `_nix_str_array`.
fn nixStrArray(a: Allocator, values: []const []const u8) Error![]const u8 {
    return std.fmt.allocPrint(a, "[ {s} ]", .{try joinQuoted(a, values, " ")});
}

/// lower.py `emit_oci_containers` (#6): one `gen/nixos/oci-containers.nix`
/// collecting every `container` node into
/// `virtualisation.oci-containers.containers`.
pub fn emitOciContainers(a: Allocator, g: *const graphmod.Graph, source_file: []const u8, nodes: []const graphmod.GraphNode) Error!Emitted {
    if (nodes.len == 0) return .{ .files = &.{}, .entries = &.{} };
    const rv = (try runtimeView(a, g)) orelse return .{ .files = &.{}, .entries = &.{} };
    const sf = source_file;

    var L = Lines.init(a);
    try moduleHeader(a, &L, sf, try std.fmt.allocPrint(a, "container {s}", .{nodes[0].name}), "OCI/Docker containers (memory/network/healthCmd → extraOptions).");
    try L.add("{ config, ... }:");
    try L.add("{");
    try L.add("  virtualisation.oci-containers.containers = {");
    for (nodes) |c| {
        try L.addFmt("    {s} = {{", .{c.name});
        // Python interpolates `_nix_literal(...)` with %s: a non-literal image
        // renders the text "None".
        try L.addFmt("      image = {s};", .{optStr(try nixLiteral(a, getProp(c.props, "image")))});
        if (getProp(c.props, "ports")) |ports_v| {
            switch (ports_v) {
                .array => |ports| if (ports.len > 0) {
                    var rendered: std.ArrayListUnmanaged([]const u8) = .empty;
                    // `_render_bind(p)` may be None -> Python's '"%s"' yields "None".
                    for (ports) |p| try rendered.append(a, optStr(try renderBind(a, p)));
                    try L.addFmt("      ports = {s};", .{try nixStrArray(a, rendered.items)});
                },
                else => {},
            }
        }
        const env = try recordValueProps(a, getProp(c.props, "environment"));
        if (env.len > 0) {
            try L.add("      environment = {");
            for (env) |e| {
                try L.addFmt("        {s} = {s};", .{ e.name, try renderSetting(a, rv, e.value) });
            }
            try L.add("      };");
        }
        if (getProp(c.props, "environmentFiles")) |ef_v| {
            switch (ef_v) {
                .array => |ef| if (ef.len > 0) {
                    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
                    for (ef) |x| {
                        // Python: `_accessor_nix(rv, _ref(x)) or (_ref(x) or "")`
                        const r = refOf(x);
                        const acc = if (r) |rr| try accessorNix(a, rv, rr) else null;
                        try paths.append(a, acc orelse (r orelse ""));
                    }
                    try L.addFmt("      environmentFiles = [ {s} ];", .{try std.mem.join(a, " ", paths.items)});
                },
                else => {},
            }
        }
        const vols = try strList(a, getProp(c.props, "volumes"));
        if (vols.len > 0) try L.addFmt("      volumes = {s};", .{try nixStrArray(a, vols)});
        const extra = try containerExtraOptions(a, c);
        if (extra.len > 0) try L.addFmt("      extraOptions = {s};", .{try nixStrArray(a, extra)});
        try L.add("    };");
    }
    try L.add("  };");
    try L.add("}");

    const files = try a.alloc(File, 1);
    files[0] = .{ .path = "gen/nixos/oci-containers.nix", .content = try L.text() };
    const entries = try a.alloc(ProvEntry, nodes.len);
    for (nodes, 0..) |c, i| {
        entries[i] = .{
            .artifact = "gen/nixos/oci-containers.nix",
            .region = try std.mem.concat(a, u8, &.{ "oci-containers.containers.", c.name }),
            .source_file = sf,
            .decl = try std.fmt.allocPrint(a, "container {s}", .{c.name}),
            .span = c.provenance.?.span,
            .emitter = "oci.containers",
            .inputs_projection = try nodeProjection(a, c),
        };
    }
    return .{ .files = files, .entries = entries };
}

// --------------------------------------------------------------------------- //
// Emitters: the runtime plane (#18/#24/#27) — eventd.config / trust.config /
// memory.store / workflow.spec. All presence-gated: a runtime declaring no
// memory/workflow/trust emits none of them, keeping earlier fixture sets
// byte-identical. JSON layout via emitZigJson (deterministic order).
//
// NOTE these DO use `_coerce_number` (unlike the NixOS cohort, which renders
// numbers verbatim via `_nix_literal`): trust.score is a Float and quorum.min
// an Int, both coerced then rendered by json.dumps. See the Python-derived
// table in lower_test.zig — this is the emitter family where the original v0.5
// number bugs lived.
// --------------------------------------------------------------------------- //

/// lower.py `_eventd_log_path`: the per-runtime hash-chained log path.
fn eventdLogPath(a: Allocator, rv: RuntimeView) Error![]const u8 {
    return std.fmt.allocPrint(a, "var/lib/{s}/eventd/log.jsonl", .{rv.runtime.name});
}

/// lower.py `emit_eventd_config` (#18): `gen/eventd.json`, the per-runtime log
/// location + boot contract. Selected when the runtime declares any
/// memory/workflow (the log's in-language consumers).
pub fn emitEventdConfig(a: Allocator, g: *const graphmod.Graph, source_file: []const u8) Error!Emitted {
    const rv = (try runtimeView(a, g)) orelse return .{ .files = &.{}, .entries = &.{} };
    const sf = source_file;
    const rt = rv.runtime;
    const rt_decl = try std.fmt.allocPrint(a, "runtime {s}", .{rt.name});

    const pairs = try a.alloc(ZigPair, 5);
    pairs[0] = .{ .key = "_generated", .val = .{ .string = try header(a, sf, rt_decl) } };
    pairs[1] = .{ .key = "log", .val = .{ .string = try eventdLogPath(a, rv) } };
    pairs[2] = .{ .key = "format", .val = .{ .string = "jsonl-hashchain-v1" } };
    pairs[3] = .{ .key = "verify_on_boot", .val = .{ .boolean = true } };
    pairs[4] = .{ .key = "writer", .val = .{ .string = "agent-supervisord" } };

    const files = try a.alloc(File, 1);
    files[0] = .{ .path = "gen/eventd.json", .content = try emitZigJson(a, .{ .object = pairs }) };
    const entries = try a.alloc(ProvEntry, 1);
    entries[0] = .{
        .artifact = "gen/eventd.json",
        .region = null,
        .source_file = sf,
        .decl = rt_decl,
        .span = rt.provenance.?.span,
        .emitter = "eventd.config",
        .inputs_projection = try nodeProjection(a, rt),
    };
    return .{ .files = files, .entries = entries };
}

/// lower.py `emit_trust_config` (v0.5): `gen/trust.json` — the trust/quorum/
/// probe topology the runtime supervisor loads to seed the sentinel subsystem,
/// consensus engine, and compaction guard.
///
/// Each entry is a PLAIN dict inside a list, so it renders INLINE with
/// json.dumps default separators (see `ZigVal.plain_object`).
pub fn emitTrustConfig(a: Allocator, g: *const graphmod.Graph, source_file: []const u8) Error!Emitted {
    const rv = (try runtimeView(a, g)) orelse return .{ .files = &.{}, .entries = &.{} };
    const sf = source_file;
    const rt = rv.runtime;
    const rt_decl = try std.fmt.allocPrint(a, "runtime {s}", .{rt.name});

    var trusts: std.ArrayListUnmanaged(ZigVal) = .empty;
    for (rv.trusts) |t| {
        var e: std.ArrayListUnmanaged(ZigPair) = .empty;
        try e.append(a, .{ .key = "name", .val = .{ .string = t.name } });
        // number literals are stored in string form — coerce like fps/min.
        if (litOf(getProp(t.props, "score"))) |score| {
            try e.append(a, .{ .key = "score", .val = .{ .raw = try coerceNumberStr(a, score) } });
        }
        if (litOf(getProp(t.props, "half_life"))) |hl| {
            try e.append(a, .{ .key = "half_life", .val = .{ .string = hl } });
        }
        if (refOf(getProp(t.props, "delegate"))) |d| {
            try e.append(a, .{ .key = "delegate", .val = .{ .string = d } });
        }
        if (litOf(getProp(t.props, "taint_as"))) |ta| {
            // Python: `entry["taint_as"] = taint_as == "true"` -> a real bool.
            try e.append(a, .{ .key = "taint_as", .val = .{ .boolean = std.mem.eql(u8, ta, "true") } });
        }
        try trusts.append(a, .{ .plain_object = try e.toOwnedSlice(a) });
    }

    var quorums: std.ArrayListUnmanaged(ZigVal) = .empty;
    for (rv.quorums) |q| {
        var e: std.ArrayListUnmanaged(ZigPair) = .empty;
        try e.append(a, .{ .key = "name", .val = .{ .string = q.name } });
        if (litOf(getProp(q.props, "min"))) |m| {
            try e.append(a, .{ .key = "min", .val = .{ .raw = try coerceNumberStr(a, m) } });
        }
        if (getProp(q.props, "over")) |over| {
            // Python iterates `over` directly: a non-list would raise, and the
            // grammar only admits a list here.
            var xs: std.ArrayListUnmanaged(ZigVal) = .empty;
            switch (over) {
                .array => |arr| for (arr) |x| {
                    if (refOf(x)) |r| try xs.append(a, .{ .string = r });
                },
                else => {},
            }
            try e.append(a, .{ .key = "over", .val = .{ .array = try xs.toOwnedSlice(a) } });
        }
        if (getProp(q.props, "timeout")) |t| {
            // `entry["timeout"] = _lit(timeout)` — a non-literal yields None,
            // which json.dumps renders as null (the key is still emitted).
            const lv = litOf(t);
            try e.append(a, .{ .key = "timeout", .val = if (lv) |s| .{ .string = s } else .none });
        }
        // on_failure is ref-valued per the grammar; tolerate a literal on
        // unchecked graphs (Python: `_ref(...) or _lit(...)`).
        const on_failure = refOf(getProp(q.props, "on_failure")) orelse litOf(getProp(q.props, "on_failure"));
        if (on_failure) |of| {
            try e.append(a, .{ .key = "on_failure", .val = .{ .string = of } });
        }
        try quorums.append(a, .{ .plain_object = try e.toOwnedSlice(a) });
    }

    var probes: std.ArrayListUnmanaged(ZigVal) = .empty;
    for (rv.probes) |p| {
        var e: std.ArrayListUnmanaged(ZigPair) = .empty;
        try e.append(a, .{ .key = "name", .val = .{ .string = p.name } });
        // `on_result` (an inline record/Block) is deliberately NOT projected:
        // §5.2 configs carry scalars/refs only.
        for ([_][]const u8{ "from", "to", "via", "with" }) |fld| {
            if (refOf(getProp(p.props, fld))) |r| {
                try e.append(a, .{ .key = fld, .val = .{ .string = r } });
            }
        }
        try probes.append(a, .{ .plain_object = try e.toOwnedSlice(a) });
    }

    const pairs = try a.alloc(ZigPair, 4);
    pairs[0] = .{ .key = "_generated", .val = .{ .string = try header(a, sf, rt_decl) } };
    pairs[1] = .{ .key = "trusts", .val = .{ .array = try trusts.toOwnedSlice(a) } };
    pairs[2] = .{ .key = "quorums", .val = .{ .array = try quorums.toOwnedSlice(a) } };
    pairs[3] = .{ .key = "probes", .val = .{ .array = try probes.toOwnedSlice(a) } };

    const files = try a.alloc(File, 1);
    files[0] = .{ .path = "gen/trust.json", .content = try emitZigJson(a, .{ .object = pairs }) };
    const entries = try a.alloc(ProvEntry, 1);
    entries[0] = .{
        .artifact = "gen/trust.json",
        .region = null,
        .source_file = sf,
        .decl = rt_decl,
        .span = rt.provenance.?.span,
        .emitter = "trust.config",
        .inputs_projection = try nodeProjection(a, rt),
    };
    return .{ .files = files, .entries = entries };
}

/// lower.py `emit_memory_store` (#24, 0014): one `gen/memory/<name>.json` per
/// memory decl — mined source, distiller, fold partition (scope), retention,
/// recall artifacts, and the eventd log the entries ride on.
pub fn emitMemoryStore(a: Allocator, g: *const graphmod.Graph, source_file: []const u8, nodes: []const graphmod.GraphNode) Error!Emitted {
    const rv = (try runtimeView(a, g)) orelse return .{ .files = &.{}, .entries = &.{} };
    const sf = source_file;
    var files: std.ArrayListUnmanaged(File) = .empty;
    var entries: std.ArrayListUnmanaged(ProvEntry) = .empty;
    for (nodes) |mem| {
        var pairs: std.ArrayListUnmanaged(ZigPair) = .empty;
        try pairs.append(a, .{
            .key = "_generated",
            .val = .{ .string = try header(a, sf, try std.fmt.allocPrint(a, "memory {s}", .{mem.name})) },
        });
        // source : Stream<T> | List<Stream<T>> — BOTH forms are schema-legal and
        // the list form must survive into the config (memoryd mines every named
        // stream). An empty resolved list emits NO `source` key at all.
        const src_prop = getProp(mem.props, "source");
        var handled_list = false;
        if (src_prop) |sp| switch (sp) {
            .array => |arr| {
                handled_list = true;
                var xs: std.ArrayListUnmanaged(ZigVal) = .empty;
                for (arr) |x| {
                    if (refOf(x)) |r| try xs.append(a, .{ .string = r });
                }
                if (xs.items.len > 0) {
                    try pairs.append(a, .{ .key = "source", .val = .{ .array = try xs.toOwnedSlice(a) } });
                }
            },
            else => {},
        };
        if (!handled_list) {
            if (refOf(src_prop)) |src| try pairs.append(a, .{ .key = "source", .val = .{ .string = src } });
        }
        if (refOf(getProp(mem.props, "schema"))) |s| {
            try pairs.append(a, .{ .key = "schema", .val = .{ .string = s } }); // binds entry type T (0014)
        }
        if (refOf(getProp(mem.props, "mine"))) |m| {
            try pairs.append(a, .{ .key = "mine", .val = .{ .string = m } });
        }
        // scope defaults to "agent" and is ALWAYS emitted.
        const scope = litOf(getProp(mem.props, "scope"));
        try pairs.append(a, .{ .key = "scope", .val = .{ .string = scope orelse "agent" } });
        if (litOf(getProp(mem.props, "retention"))) |r| {
            try pairs.append(a, .{ .key = "retention", .val = .{ .string = r } });
        }
        if (getProp(mem.props, "emit")) |emit_prop| switch (emit_prop) {
            .array => |arr| {
                var xs: std.ArrayListUnmanaged(ZigVal) = .empty;
                for (arr) |x| {
                    if (refOf(x)) |r| try xs.append(a, .{ .string = r });
                }
                if (xs.items.len > 0) {
                    try pairs.append(a, .{ .key = "emit", .val = .{ .array = try xs.toOwnedSlice(a) } });
                }
            },
            else => {},
        };
        try pairs.append(a, .{ .key = "log", .val = .{ .string = try eventdLogPath(a, rv) } });

        const path = try std.fmt.allocPrint(a, "gen/memory/{s}.json", .{mem.name});
        try files.append(a, .{ .path = path, .content = try emitZigJson(a, .{ .object = try pairs.toOwnedSlice(a) }) });
        try entries.append(a, .{
            .artifact = path,
            .region = null,
            .source_file = sf,
            .decl = try std.fmt.allocPrint(a, "memory {s}", .{mem.name}),
            .span = mem.provenance.?.span,
            .emitter = "memory.store",
            .inputs_projection = try nodeProjection(a, mem),
        });
    }
    return .{ .files = try files.toOwnedSlice(a), .entries = try entries.toOwnedSlice(a) };
}

/// lower.py `_budget_prop`: the Budget auxiliary type admits BOTH a ref to a
/// `budget` decl (emitted as the ref string) and an inline record (emitted as
/// an ordered object). Dropping either would boot the supervisor without
/// declared limits. Null when neither form matches (or the record has no
/// literal-valued entries).
fn budgetProp(a: Allocator, prop: ?json.Value) Error!?ZigVal {
    if (refOf(prop)) |r| return ZigVal{ .string = r };
    const v = prop orelse return null;
    const rec = getProp(v, "record") orelse return null;
    const arr = switch (rec) {
        .array => |x| x,
        else => return null,
    };
    var pairs: std.ArrayListUnmanaged(ZigPair) = .empty;
    for (arr) |e| {
        const assign = getProp(e, "assign") orelse continue;
        const name = switch (assign) {
            .string => |s| s,
            else => continue,
        };
        const value = getProp(e, "value");
        const lit = litOf(value) orelse continue; // `if lit is None: continue`
        // Only NUMBER literals are coerced; everything else stays a string.
        const is_number = blk: {
            const vv = value orelse break :blk false;
            const k = getProp(vv, "lit") orelse break :blk false;
            break :blk switch (k) {
                .string => |s| std.mem.eql(u8, s, "number"),
                else => false,
            };
        };
        try pairs.append(a, .{
            .key = name,
            .val = if (is_number) .{ .raw = try coerceNumberStr(a, lit) } else .{ .string = lit },
        });
    }
    if (pairs.items.len == 0) return null;
    return ZigVal{ .object = try pairs.toOwnedSlice(a) };
}

/// lower.py `_workflow_depth`: critical path counted in steps (same semantics
/// as the 0015 checker). `lower` runs only on a checked graph, so the edge set
/// is a DAG and the recursion terminates.
fn workflowDepth(a: Allocator, steps: []const graphmod.GraphNode, edges: []const Edge) Error!i64 {
    var succ: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty;
    for (steps) |s| try succ.put(a, s.name, .empty);
    for (edges) |e| {
        // Python `succ[a].append(b)` — a KeyError if `a` is not a step, which
        // cannot happen: stepsEdges only yields edges between steps.
        if (succ.getPtr(e.from)) |lst| try lst.append(a, e.to);
    }
    var memo: std.StringHashMapUnmanaged(i64) = .empty;
    var best: i64 = 0;
    for (steps) |s| {
        const d = try workflowDepthOf(a, &succ, &memo, s.name);
        if (d > best) best = d;
    }
    return best; // `max(..., default=0)`
}

fn workflowDepthOf(
    a: Allocator,
    succ: *std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),
    memo: *std.StringHashMapUnmanaged(i64),
    name: []const u8,
) Error!i64 {
    if (memo.get(name)) |m| return m;
    var best: i64 = 0;
    if (succ.get(name)) |lst| {
        for (lst.items) |n| {
            const d = try workflowDepthOf(a, succ, memo, n);
            if (d > best) best = d;
        }
    }
    const r = 1 + best;
    try memo.put(a, name, r);
    return r;
}

/// lower.py `_workflow_projection`: the artifact depends on the workflow record
/// AND its step nodes AND the routes_to edges (they produce steps/edges/depth),
/// so ALL of them key the inputsHash — editing a step's agent or rewiring the
/// DAG must change the hash.
fn workflowProjection(a: Allocator, wf: graphmod.GraphNode, steps: []const graphmod.GraphNode, edges: []const Edge) Error!json.Value {
    const base = try nodeProjection(a, wf);
    const base_obj = switch (base) {
        .object => |o| o,
        else => &[_]json.Value.Entry{},
    };
    const step_vals = try a.alloc(json.Value, steps.len);
    for (steps, 0..) |s, i| step_vals[i] = try nodeProjection(a, s);
    const edge_vals = try a.alloc(json.Value, edges.len);
    for (edges, 0..) |e, i| {
        const o = try a.alloc(json.Value.Entry, 2);
        o[0] = .{ .key = "from", .value = .{ .string = e.from } };
        o[1] = .{ .key = "to", .value = .{ .string = e.to } };
        edge_vals[i] = .{ .object = o };
    }
    const out = try a.alloc(json.Value.Entry, base_obj.len + 2);
    @memcpy(out[0..base_obj.len], base_obj);
    out[base_obj.len] = .{ .key = "steps", .value = .{ .array = step_vals } };
    out[base_obj.len + 1] = .{ .key = "edges", .value = .{ .array = edge_vals } };
    return .{ .object = out };
}

/// lower.py `emit_workflow_spec` (#27, 0015): one `gen/workflow/<name>.json`
/// per workflow decl — the AOT spec agent-supervisord loads at boot.
pub fn emitWorkflowSpec(a: Allocator, g: *const graphmod.Graph, source_file: []const u8, nodes: []const graphmod.GraphNode) Error!Emitted {
    const rv = (try runtimeView(a, g)) orelse return .{ .files = &.{}, .entries = &.{} };
    const sf = source_file;
    var files: std.ArrayListUnmanaged(File) = .empty;
    var entries: std.ArrayListUnmanaged(ProvEntry) = .empty;
    for (nodes) |wf| {
        const se = try stepsEdges(a, g, wf);
        var pairs: std.ArrayListUnmanaged(ZigPair) = .empty;
        try pairs.append(a, .{
            .key = "_generated",
            .val = .{ .string = try header(a, sf, try std.fmt.allocPrint(a, "workflow {s}", .{wf.name})) },
        });
        if (litOf(getProp(wf.props, "on"))) |on| {
            try pairs.append(a, .{ .key = "on", .val = .{ .string = on } });
        }
        if (try budgetProp(a, getProp(wf.props, "budget"))) |b| {
            try pairs.append(a, .{ .key = "budget", .val = b });
        }
        if (litOf(getProp(wf.props, "maxDepth"))) |md| {
            try pairs.append(a, .{ .key = "maxDepth", .val = .{ .raw = try coerceNumberStr(a, md) } });
        }
        var step_objs: std.ArrayListUnmanaged(ZigVal) = .empty;
        for (se.steps) |st| {
            var sp: std.ArrayListUnmanaged(ZigPair) = .empty;
            try sp.append(a, .{ .key = "name", .val = .{ .string = st.name } });
            if (refOf(getProp(st.props, "agent"))) |ag| {
                try sp.append(a, .{ .key = "agent", .val = .{ .string = ag } });
            }
            for ([_][]const u8{ "input", "output" }) |fld| {
                if (refOf(getProp(st.props, fld))) |r| {
                    try sp.append(a, .{ .key = fld, .val = .{ .string = r } });
                }
            }
            if (litOf(getProp(st.props, "retries"))) |r| {
                try sp.append(a, .{ .key = "retries", .val = .{ .raw = try coerceNumberStr(a, r) } });
            }
            if (try budgetProp(a, getProp(st.props, "budget"))) |b| {
                try sp.append(a, .{ .key = "budget", .val = b });
            }
            step_objs.append(a, .{ .object = try sp.toOwnedSlice(a) }) catch return error.OutOfMemory;
        }
        try pairs.append(a, .{ .key = "steps", .val = .{ .array = try step_objs.toOwnedSlice(a) } });

        var edge_objs: std.ArrayListUnmanaged(ZigVal) = .empty;
        for (se.edges) |e| {
            const o = try a.alloc(ZigPair, 2);
            o[0] = .{ .key = "from", .val = .{ .string = e.from } };
            o[1] = .{ .key = "to", .val = .{ .string = e.to } };
            try edge_objs.append(a, .{ .object = o });
        }
        try pairs.append(a, .{ .key = "edges", .val = .{ .array = try edge_objs.toOwnedSlice(a) } });

        const depth = try workflowDepth(a, se.steps, se.edges);
        try pairs.append(a, .{ .key = "depth", .val = .{ .raw = try std.fmt.allocPrint(a, "{d}", .{depth}) } });
        try pairs.append(a, .{ .key = "log", .val = .{ .string = try eventdLogPath(a, rv) } });

        const path = try std.fmt.allocPrint(a, "gen/workflow/{s}.json", .{wf.name});
        try files.append(a, .{ .path = path, .content = try emitZigJson(a, .{ .object = try pairs.toOwnedSlice(a) }) });
        try entries.append(a, .{
            .artifact = path,
            .region = null,
            .source_file = sf,
            .decl = try std.fmt.allocPrint(a, "workflow {s}", .{wf.name}),
            .span = wf.provenance.?.span,
            .emitter = "workflow.spec",
            .inputs_projection = try workflowProjection(a, wf, se.steps, se.edges),
        });
    }
    return .{ .files = try files.toOwnedSlice(a), .entries = try entries.toOwnedSlice(a) };
}

// --------------------------------------------------------------------------- //
// Emitter: colmena.hive (per host decl) — gen/colmena/hive.nix.
// --------------------------------------------------------------------------- //

/// lower.py `emit_colmena_hive` (#51): one colmena node per `host` decl, so
/// `colmena apply` deploys the runtime's nixosModules to its declared boxes.
///
/// `deploy = "ssh://user@addr"` -> deployment.targetHost "user@addr";
/// `deploy = "local"` (or absent) -> local deployment.
pub fn emitColmenaHive(a: Allocator, g: *const graphmod.Graph, source_file: []const u8, nodes: []const graphmod.GraphNode) Error!Emitted {
    const rv = (try runtimeView(a, g)) orelse return .{ .files = &.{}, .entries = &.{} };
    const sf = source_file;
    const rt = rv.runtime;

    var L = Lines.init(a);
    try L.addFmt("# {s}", .{try header(a, sf, try std.fmt.allocPrint(a, "runtime {s}", .{rt.name}))});
    try L.add("#");
    try L.addFmt("# colmena hive (#51): `colmena apply` deploys nixosModules.{s}", .{rt.name});
    try L.add("# to the declared hosts. Standalone form pins nothing itself —");
    try L.add("# the flake (the spine) is the pinned entry point; <nixpkgs>");
    try L.add("# here is the documented interface-only escape (0012 §4.3).");
    try L.add("{");
    try L.add("  meta = {");
    // PATH form (not `import <nixpkgs> {}`): colmena imports nixpkgs per node,
    // honoring each node's `nixpkgs.system`. An already-evaluated set would be
    // used as-is and the per-node system silently ignored (multi-arch bug).
    try L.add("    nixpkgs = <nixpkgs>;");
    try L.add("  };");
    try L.add("");

    var entries: std.ArrayListUnmanaged(ProvEntry) = .empty;
    for (nodes, 0..) |h, i| {
        if (i != 0) try L.add(""); // blank line BETWEEN nodes only
        // Python: `_lit(...) or ""` — absent AND empty both yield "".
        const system = blk: {
            const s = litOf(getProp(h.props, "system")) orelse break :blk "";
            break :blk s;
        };
        const deploy = litOf(getProp(h.props, "deploy"));
        // All host-controlled strings go through _nix_str — host name, deploy
        // target and system are free-form (deploy is only `nonempty String`),
        // so raw interpolation would allow `${…}` antiquotation injection (the
        // #7 attrpath-splice class). _nix_str neutralizes it.
        try L.addFmt("  {s} = {{ ... }}: {{", .{try nixStr(a, h.name)});
        if (deploy == null or std.mem.eql(u8, deploy.?, "local")) {
            try L.add("    deployment.allowLocalDeployment = true;");
            // targetHost defaults to the node NAME in colmena; null disables
            // SSH so plain `colmena apply` treats this node as local.
            try L.add("    deployment.targetHost = null;");
        } else {
            const d = deploy.?;
            const target = if (std.mem.startsWith(u8, d, "ssh://")) d[6..] else d;
            try L.addFmt("    deployment.targetHost = {s};", .{try nixStr(a, target)});
        }
        try L.addFmt("    nixpkgs.system = {s};", .{try nixStr(a, system)});
        try L.add("    # interface-only module path, exactly as the spine");
        try L.addFmt("    # declares nixosModules.{s} (0012 §4.3).", .{rt.name});
        try L.addFmt("    imports = [ ../../nixos/{s}.nix ];", .{rt.name});
        try L.add("  };");
        try entries.append(a, .{
            .artifact = "gen/colmena/hive.nix",
            .region = try std.mem.concat(a, u8, &.{ "host/", h.name }),
            .source_file = sf,
            .decl = try std.fmt.allocPrint(a, "host {s}", .{h.name}),
            .span = h.provenance.?.span,
            .emitter = "colmena.hive",
            .inputs_projection = try nodeProjection(a, h),
        });
    }
    try L.add("}");

    const files = try a.alloc(File, 1);
    files[0] = .{ .path = "gen/colmena/hive.nix", .content = try L.text() };
    return .{ .files = files, .entries = try entries.toOwnedSlice(a) };
}

// --------------------------------------------------------------------------- //
// Emitter: ebpf.policy (per network membrane) — gen/ebpf.policy.json.
//
// NOT a deferred slot, despite three stale docstrings in lower.py saying so
// (L41, L1554's `emit_deferred` docstring, and the EMITTER_REGISTRY comment in
// tests/spec/test_lowering_fixtures.py L54). Resolved from the code, not the
// prose: the registry row is `_Registered("ebpf.policy", emit_ebpf_policy)`
// with NO `deferred=True` — unlike catalog.sqlite/otel.config/systemd.units/
// surface.launcher, which do carry it — and `lower()` L2452 dispatches
// `_run("ebpf.policy", rv.networks)`. The registry's own comment says
// "(§7, realized)". The docstrings are drift from when it was promoted;
// reported, not fixed.
//
// Serialization: a THIRD layout. `json.dumps(doc, indent=2, sort_keys=True,
// ensure_ascii=False)` — pretty, 2-space, keys SORTED (not emit order), and
// with `indent` set Python's item separator loses its trailing space (","
// not ", "). Neither writeCanonical (compact) nor emitZigJson (_Ordered,
// unsorted) nor jsonDumpsDefault (one line, ", ") is this.
// --------------------------------------------------------------------------- //

/// Python `ipaddress._parse_octet` semantics for one IPv4 octet: ASCII digits
/// only, at most 3 of them, NO leading zero when longer than one digit
/// (CPython >= 3.9.5 rejects `010.0.0.1`), value <= 255.
fn validIpv4Octet(s: []const u8) bool {
    if (s.len == 0 or s.len > 3) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false; // also rejects '+'/'-'/spaces
    }
    if (s.len > 1 and s[0] == '0') return false; // ambiguous leading zero
    const v = std.fmt.parseInt(u16, s, 10) catch return false;
    return v <= 255;
}

/// Python `ipaddress.IPv4Address(s)` validity: exactly 4 dot-separated octets.
fn validIpv4(s: []const u8) bool {
    var it = std.mem.splitScalar(u8, s, '.');
    var n: usize = 0;
    while (it.next()) |part| {
        n += 1;
        if (n > 4) return false;
        if (!validIpv4Octet(part)) return false;
    }
    return n == 4;
}

/// Python `ipaddress.IPv6Address(s)` validity: up to 8 groups of 1-4 hex
/// digits, at most one `::` run, and an optional trailing embedded IPv4
/// (`::ffff:1.2.3.4`) which consumes two groups.
fn validIpv6(s: []const u8) bool {
    if (s.len == 0) return false;
    // At most one "::"; find it.
    const dbl = std.mem.indexOf(u8, s, "::");
    if (dbl) |d| {
        if (std.mem.indexOf(u8, s[d + 1 ..], "::") != null) return false; // a second run
    }
    var head: []const u8 = s;
    var tail: []const u8 = "";
    if (dbl) |d| {
        head = s[0..d];
        tail = s[d + 2 ..];
        // A leading/trailing single ':' outside the "::" is malformed
        // (":1::2" / "1::2:"), which the group walk below catches via an
        // empty group.
    } else {
        // No "::": a leading or trailing ':' is malformed.
        if (s[0] == ':' or s[s.len - 1] == ':') return false;
    }
    var groups: usize = 0;
    for ([_][]const u8{ head, tail }, 0..) |seg, seg_i| {
        if (seg.len == 0) continue;
        var it = std.mem.splitScalar(u8, seg, ':');
        var parts: std.ArrayListUnmanaged([]const u8) = .empty;
        var buf: [16][]const u8 = undefined;
        var n: usize = 0;
        while (it.next()) |p| {
            if (n >= buf.len) return false;
            buf[n] = p;
            n += 1;
        }
        _ = &parts;
        for (buf[0..n], 0..) |p, i| {
            const is_last_of_tail = (seg_i == 1 and i == n - 1);
            const is_last_of_head = (seg_i == 0 and i == n - 1 and dbl == null);
            // an embedded IPv4 may only appear as the FINAL group
            if ((is_last_of_tail or is_last_of_head) and std.mem.indexOfScalar(u8, p, '.') != null) {
                if (!validIpv4(p)) return false;
                groups += 2; // an embedded v4 occupies two 16-bit groups
                continue;
            }
            if (p.len == 0 or p.len > 4) return false;
            for (p) |c| {
                if (!std.ascii.isHex(c)) return false;
            }
            groups += 1;
        }
    }
    if (dbl == null) return groups == 8;
    // "::" must stand for AT LEAST one omitted group.
    return groups < 8;
}

/// Python `ipaddress._prefix_from_prefix_string`: ASCII digits only (so `+32`
/// and ` 32` are rejected), leading zeros ALLOWED (`/032` is valid), value
/// within 0..max.
fn validPrefixLen(s: []const u8, max: u16) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    const v = std.fmt.parseInt(u32, s, 10) catch return false;
    return v <= max;
}

/// True when the `/`-part is a valid IPv4 netmask (contiguous high 1-bits) or
/// hostmask (its inverse) — Python's `_prefix_from_ip_string` tries the mask,
/// then the inverted mask.
fn validIpv4MaskString(s: []const u8) bool {
    if (!validIpv4(s)) return false;
    var v: u32 = 0;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |part| {
        const o = std.fmt.parseInt(u8, part, 10) catch return false;
        v = (v << 8) | o;
    }
    return isContiguousMask(v) or isContiguousMask(~v);
}

/// A netmask is contiguous 1s from the top: `~v + 1` is a power of two (with 0
/// and all-ones handled).
fn isContiguousMask(v: u32) bool {
    const inv = ~v;
    return (inv & (inv +% 1)) == 0;
}

/// lower.py `_host_cidr`: the single-host CIDR for a bare `host` literal —
/// `/32` IPv4, `/128` IPv6. A host already carrying a `/prefix` is kept
/// VERBATIM (so the `/` branch is pure validation). Null for a host that is
/// neither a valid IP literal nor an explicit CIDR: a non-IP destination is
/// not attestable at the packet layer (decide() denies it), so it must never
/// be widened into a subnet.
pub fn hostCidr(a: Allocator, host: []const u8) Error!?[]const u8 {
    if (std.mem.indexOfScalar(u8, host, '/') != null) {
        // Python: `ip_network(host, strict=False)`; on success return `host`.
        var it = std.mem.splitScalar(u8, host, '/');
        const addr = it.next() orelse return null;
        const prefix = it.next() orelse return null;
        if (it.next() != null) return null; // more than one '/'
        if (validIpv4(addr)) {
            if (validPrefixLen(prefix, 32) or validIpv4MaskString(prefix)) return host;
            return null;
        }
        if (validIpv6(addr)) {
            // IPv6Network takes an integer prefix only — no netmask strings.
            if (validPrefixLen(prefix, 128)) return host;
            return null;
        }
        return null;
    }
    if (validIpv4(host)) return try std.fmt.allocPrint(a, "{s}/32", .{host});
    if (validIpv6(host)) return try std.fmt.allocPrint(a, "{s}/128", .{host});
    return null;
}

/// Python `str(int(s))` where a non-integer RAISES (the caller drops the rule)
/// — unlike `_coerce_number`, which returns the string unchanged. So
/// `egress("h", 9.5)` drops the rule entirely.
pub fn pyIntStrict(a: Allocator, s: []const u8) Error!?[]const u8 {
    const t = std.mem.trim(u8, s, " \t\n\r\x0b\x0c"); // int() strips whitespace
    var i: usize = 0;
    if (t.len > 0 and (t[0] == '-' or t[0] == '+')) i = 1;
    if (i >= t.len) return null;
    for (t[i..]) |c| {
        if (!std.ascii.isDigit(c)) return null; // '.'/'e' -> ValueError
    }
    const neg = t.len > 0 and t[0] == '-';
    var start = i;
    while (start + 1 < t.len and t[start] == '0') start += 1;
    const digits = t[start..];
    if (digits.len == 1 and digits[0] == '0') return "0";
    if (!neg) return digits;
    const joined: []const u8 = try std.mem.concat(a, u8, &.{ "-", digits });
    return joined;
}

/// lower.py `_principal_network_grant`: the `network.<grant>` a mesh
/// `node <principal>` holds — its position in the builtin `network` lattice
/// (none < loopback < lan < egress). Best effort; null when absent.
///
/// NOTE the scan is `graph.nodes_sorted()` — id order, NOT source order — and
/// returns the FIRST match, so the sort is load-bearing for determinism.
fn principalNetworkGrant(a: Allocator, g: *const graphmod.Graph, principal: ?[]const u8) Error!?[]const u8 {
    const p = principal orelse return null;
    if (p.len == 0) return null; // Python: `if not principal`
    for (try nodesSorted(a, g)) |n| {
        if (!std.mem.eql(u8, n.kind, "node")) continue;
        if (!std.mem.eql(u8, n.name, p)) continue;
        const caps = getProp(n.props, "capabilities") orelse continue;
        switch (caps) {
            .array => |arr| for (arr) |c| {
                const r = refOf(c) orelse continue;
                // Python: `r.split(".", 1)[0] == "network"`
                const head = if (std.mem.indexOfScalar(u8, r, '.')) |i| r[0..i] else r;
                if (std.mem.eql(u8, head, "network")) return r;
            },
            else => {},
        }
    }
    return null;
}

/// lower.py `_egress_rule`: one allow-rule from an `egress(host, port)` call ->
/// an ordered dict {proto, host, cidr, port}. The host is pinned to a
/// single-address CIDR so an allow rule never widens into a subnet. Null for a
/// malformed call (non-string host, non-numeric port, or a host that is
/// neither a valid IP literal nor an explicit CIDR).
fn egressRule(a: Allocator, call: ?AppCall) Error!?ZigVal {
    const c = call orelse return null;
    if (!std.mem.eql(u8, c.ref, "egress")) return null;
    if (c.args.len < 2) return null;
    const host = c.args[0] orelse return null; // `not isinstance(host, str)`
    const port_s = c.args[1] orelse return null; // int(None) -> TypeError
    const port = (try pyIntStrict(a, port_s)) orelse return null;
    const cidr = (try hostCidr(a, host)) orelse return null;
    const o = try a.alloc(ZigPair, 4);
    o[0] = .{ .key = "proto", .val = .{ .string = "tcp" } };
    o[1] = .{ .key = "host", .val = .{ .string = host } };
    o[2] = .{ .key = "cidr", .val = .{ .string = cidr } };
    o[3] = .{ .key = "port", .val = .{ .raw = port } };
    return ZigVal{ .plain_object = o };
}

/// `json.dumps(v, indent=2, sort_keys=True, ensure_ascii=False)`.
///
/// With `indent` set, Python's separators become `(",", ": ")` — the item
/// separator loses its trailing space, and each item goes on its own line.
/// Empty containers stay `{}` / `[]`. Keys are SORTED (byte order == code
/// point order for UTF-8).
fn jsonDumpsIndentSorted(a: Allocator, v: ZigVal, level: usize, out: *std.ArrayListUnmanaged(u8)) Error!void {
    const pad = try repeatStr(a, "  ", level);
    const pad_in = try repeatStr(a, "  ", level + 1);
    switch (v) {
        .plain_object, .object => |pairs| {
            if (pairs.len == 0) {
                try out.appendSlice(a, "{}");
                return;
            }
            const sorted = try a.dupe(ZigPair, pairs);
            std.sort.block(ZigPair, sorted, {}, struct {
                fn less(_: void, x: ZigPair, y: ZigPair) bool {
                    return std.mem.order(u8, x.key, y.key) == .lt;
                }
            }.less);
            try out.appendSlice(a, "{\n");
            for (sorted, 0..) |p, i| {
                try out.appendSlice(a, pad_in);
                try out.appendSlice(a, try jsonScalar(a, .{ .string = p.key }));
                try out.appendSlice(a, ": ");
                try jsonDumpsIndentSorted(a, p.val, level + 1, out);
                if (i < sorted.len - 1) try out.append(a, ',');
                try out.append(a, '\n');
            }
            try out.appendSlice(a, pad);
            try out.append(a, '}');
        },
        .array => |arr| {
            if (arr.len == 0) {
                try out.appendSlice(a, "[]");
                return;
            }
            try out.appendSlice(a, "[\n");
            for (arr, 0..) |x, i| {
                try out.appendSlice(a, pad_in);
                try jsonDumpsIndentSorted(a, x, level + 1, out);
                if (i < arr.len - 1) try out.append(a, ',');
                try out.append(a, '\n');
            }
            try out.appendSlice(a, pad);
            try out.append(a, ']');
        },
        .raw => |s| try out.appendSlice(a, s),
        .string => |s| try out.appendSlice(a, try jsonScalar(a, .{ .string = s })),
        .boolean => |b| try out.appendSlice(a, if (b) "true" else "false"),
        .none => try out.appendSlice(a, "null"),
        .passthrough => |pv| try jsonDumpsDefault(a, pv, out),
    }
}

/// lower.py `emit_ebpf_policy` (0012 §7, realized): `gen/ebpf.policy.json` —
/// the compiled egress policy agent-guardd loads. One `membranes[]` entry per
/// `network` decl: deny-by-default posture + the host:port allow-set, tagged
/// with the principal and its `network.<grant>` lattice position.
pub fn emitEbpfPolicy(a: Allocator, g: *const graphmod.Graph, source_file: []const u8, nodes: []const graphmod.GraphNode) Error!Emitted {
    const sf = source_file;
    const rv_opt = try runtimeView(a, g);
    // Python: `rv.runtime.name if rv is not None else ""` — this emitter does
    // NOT bail out when the runtime is missing, unlike its siblings.
    const rt_name: []const u8 = if (rv_opt) |rv| rv.runtime.name else "";

    var membranes: std.ArrayListUnmanaged(ZigVal) = .empty;
    var entries: std.ArrayListUnmanaged(ProvEntry) = .empty;
    for (nodes) |net| {
        const principal = litOf(getProp(net.props, "principal"));
        // Python: `_lit(...) or "deny"` — absent AND empty both yield "deny".
        const default = blk: {
            const d = litOf(getProp(net.props, "default")) orelse break :blk "deny";
            if (d.len == 0) break :blk "deny";
            break :blk d;
        };
        var allow: std.ArrayListUnmanaged(ZigVal) = .empty;
        if (getProp(net.props, "allow")) |allow_prop| switch (allow_prop) {
            .array => |arr| for (arr) |item| {
                if (try egressRule(a, try appCall(a, item))) |rule| try allow.append(a, rule);
            },
            else => {},
        };
        var m: std.ArrayListUnmanaged(ZigPair) = .empty;
        try m.append(a, .{ .key = "membrane", .val = .{ .string = net.name } });
        // `principal` and `grant` are ALWAYS emitted, null when absent.
        try m.append(a, .{ .key = "principal", .val = if (principal) |p| .{ .string = p } else .none });
        const grant = try principalNetworkGrant(a, g, principal);
        try m.append(a, .{ .key = "grant", .val = if (grant) |x| .{ .string = x } else .none });
        try m.append(a, .{ .key = "default", .val = .{ .string = default } });
        try m.append(a, .{ .key = "allow", .val = .{ .array = try allow.toOwnedSlice(a) } });
        if (refOf(getProp(net.props, "observe"))) |o| {
            try m.append(a, .{ .key = "observe", .val = .{ .string = o } });
        }
        try membranes.append(a, .{ .plain_object = try m.toOwnedSlice(a) });
        try entries.append(a, .{
            .artifact = "gen/ebpf.policy.json",
            .region = net.name,
            .source_file = sf,
            .decl = try std.fmt.allocPrint(a, "network {s}", .{net.name}),
            .span = net.provenance.?.span,
            .emitter = "ebpf.policy",
            .inputs_projection = try nodeProjection(a, net),
        });
    }

    const doc = try a.alloc(ZigPair, 4);
    doc[0] = .{ .key = "_generated", .val = .{ .string = try header(a, sf, try std.fmt.allocPrint(a, "runtime {s}", .{rt_name})) } };
    doc[1] = .{ .key = "version", .val = .{ .raw = "1" } };
    doc[2] = .{ .key = "runtime", .val = .{ .string = rt_name } };
    doc[3] = .{ .key = "membranes", .val = .{ .array = try membranes.toOwnedSlice(a) } };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    try jsonDumpsIndentSorted(a, .{ .plain_object = doc }, 0, &out);
    try out.append(a, '\n');

    const files = try a.alloc(File, 1);
    files[0] = .{ .path = "gen/ebpf.policy.json", .content = try out.toOwnedSlice(a) };
    return .{ .files = files, .entries = try entries.toOwnedSlice(a) };
}

// --------------------------------------------------------------------------- //
// enrich_graph — recover load-bearing config sub-blocks the resolver drops.
// --------------------------------------------------------------------------- //

/// lower.py `_CONFIG_BLOCK_FIELDS`.
fn configBlockFields(kind: []const u8) []const []const u8 {
    if (std.mem.eql(u8, kind, "fiber")) return &.{"policy"};
    if (std.mem.eql(u8, kind, "service")) return &.{"options"};
    if (std.mem.eql(u8, kind, "container")) return &.{"environment"};
    return &.{};
}

/// lower.py `_config_block_name`: the field name of a bare config-block App
/// (`policy { … }`) — a single dotted ref with a `record` body and NO call
/// args. Null when `app` is not a bare config block.
fn configBlockName(app: parser.App) ?[]const u8 {
    if (app.args != null) return null;
    if (app.record == null) return null;
    if (app.ref.parts.len != 1) return null;
    return app.ref.parts[0];
}

/// lower.py `enrich_graph`: attach dropped config sub-blocks (a fiber's
/// `policy { … }`) to their graph nodes, in place. Pure; idempotent; adds no
/// nodes/edges. Run by the lowering driver after resolve, before the emitters.
///
/// Python builds one O(N) index from `graph.nodes` (insertion-ordered) mapping
/// an id's `'#<chain>'` suffix -> the FIRST node carrying it. A node id is
/// `<basename>#<chain>` with exactly one '#', and `basename` is constant for a
/// single file, so the suffix is unique per id and the "first wins" tie-break
/// is unobservable — which is what makes the Zig StringHashMap walk (no
/// insertion order) byte-equivalent here.
pub fn enrichGraph(a: Allocator, g: *graphmod.Graph, items: []const parser.Item) Error!void {
    var index = std.StringHashMap([]const u8).init(a);
    var it = g.nodes.iterator();
    while (it.next()) |kv| {
        const n = kv.value_ptr.*;
        if (n.provenance == null) continue;
        const h = std.mem.indexOfScalar(u8, n.id, '#') orelse continue;
        const gop = try index.getOrPut(n.id[h..]);
        if (!gop.found_existing) gop.value_ptr.* = n.id;
    }

    var chain: std.ArrayListUnmanaged([]const u8) = .empty;
    for (items) |item| {
        switch (item) {
            .decl => |d| {
                chain.clearRetainingCapacity();
                try chain.append(a, d.name);
                try enrichWalk(a, g, &index, d, &chain);
            },
            else => {},
        }
    }
}

fn enrichWalk(
    a: Allocator,
    g: *graphmod.Graph,
    index: *std.StringHashMap([]const u8),
    decl: *const parser.Decl,
    chain: *std.ArrayListUnmanaged([]const u8),
) Error!void {
    const key = try std.mem.concat(a, u8, &.{ "#", try std.mem.join(a, "/", chain.items) });
    if (index.get(key)) |node_id| {
        if (g.nodes.getPtr(node_id)) |node| {
            const allowed = configBlockFields(decl.kind);
            for (decl.body) |st| {
                switch (st) {
                    .app => |app| {
                        const name = configBlockName(app) orelse continue;
                        if (!containsStr(allowed, name)) continue;
                        if (getProp(node.props, name) != null) continue;
                        const val = try resolve_mod.valueToPropsAlloc(a, .{ .app = app });
                        node.props = try objectAppend(a, node.props, name, val);
                    },
                    else => {},
                }
            }
        }
    }
    for (decl.body) |st| {
        switch (st) {
            .decl => |d| {
                try chain.append(a, d.name);
                try enrichWalk(a, g, index, d, chain);
                _ = chain.pop();
            },
            else => {},
        }
    }
}

/// `node.props[name] = value` on an immutable `json.Value.object`: reallocate
/// with the new entry APPENDED, mirroring Python dict insertion order. Order is
/// unobservable downstream (every projection sorts via `canonicalValue`, and
/// props are otherwise read by key), but appending keeps the two in step.
fn objectAppend(a: Allocator, props: json.Value, name: []const u8, value: json.Value) Error!json.Value {
    const old: []const json.Value.Entry = switch (props) {
        .object => |o| o,
        else => &.{},
    };
    const out = try a.alloc(json.Value.Entry, old.len + 1);
    @memcpy(out[0..old.len], old);
    out[old.len] = .{ .key = name, .value = value };
    return .{ .object = out };
}

// --------------------------------------------------------------------------- //
// The registry + the driver
// --------------------------------------------------------------------------- //

/// lower.py `LowerResult`.
pub const LowerResult = struct {
    /// Emitted artifacts, sorted by path (`_write_tree` writes in sorted
    /// order). Paths are unique: a later emitter writing the same path
    /// replaces the earlier content, exactly like Python's `files[path] = …`.
    files: []const File,
    /// The provenance.json document (0012 §6.2), as an ordered JSON value.
    provenance: json.Value,
    /// The flat ProvEntry list (debug/tests).
    entries: []const ProvEntry,
};

/// lower.py `lower`. Selection is entirely a read of the graph (0012 §3.3):
///
///   * `nix.spine` ALWAYS (the crabcc index derivation is folded in);
///   * `docs.runtime` on presence of the runtime node;
///   * `zig.daemoncfg` for each fiber;
///   * `catalog.jsonl` for each index whose `emit` contains `catalog.jsonl`;
///   * `crabcc.index` provenance for each index whose `emit` contains
///     `nix.derivation` (emitted inside the spine);
///   * deferred targets emit nothing.
///
/// When `items` (the parsed AST the graph was built from) is supplied, the
/// driver-side `enrichGraph` pass runs first to recover load-bearing config
/// sub-blocks; this is in-memory only and never touches `vakedz parse`'s graph
/// JSON. The per-target emitters themselves remain pure functions of the graph.
///
/// !! MUTATES `g` IN PLACE !! (only when `items != null`). `enrichGraph` adds
/// props — a fiber's `policy`, a service's `options`, a container's
/// `environment` — to existing nodes; it adds no nodes or edges and is
/// idempotent. This mirrors vakedc, whose `lower(graph, items)` calls
/// `enrich_graph(graph, items)` on the caller's graph object.
///
/// Consequence for callers: a graph handed to `lower` is NOT safe to reuse
/// afterwards where the pre-enrichment props matter — most importantly, do not
/// serialize it with `emit.toCanonicalJson` expecting `vakedz parse` bytes,
/// because the enriched props WOULD appear. `check` -> `lower` on one graph is
/// fine (check runs first, and the driver in main.zig re-parses anyway); build
/// a fresh graph if you need both the parse projection and the lowering.
pub fn lower(a: Allocator, g: *graphmod.Graph, source_file: []const u8, items: ?[]const parser.Item) Error!LowerResult {
    if (items) |its| try enrichGraph(a, g, its);

    const rv_opt = try runtimeView(a, g);
    const rv = rv_opt orelse return LowerResult{
        .files = &.{},
        .provenance = try emptyProvenance(a, source_file),
        .entries = &.{},
    };

    var files: std.ArrayListUnmanaged(File) = .empty;
    var all_entries: std.ArrayListUnmanaged(ProvEntry) = .empty;

    const run = struct {
        fn call(
            alloc: Allocator,
            fs: *std.ArrayListUnmanaged(File),
            es: *std.ArrayListUnmanaged(ProvEntry),
            emitted: Emitted,
        ) Error!void {
            for (emitted.files) |f| {
                // `files[path] = content` — last write wins.
                for (fs.items) |*existing| {
                    if (std.mem.eql(u8, existing.path, f.path)) {
                        existing.content = f.content;
                        break;
                    }
                } else try fs.append(alloc, f);
            }
            try es.appendSlice(alloc, emitted.entries);
        }
    }.call;

    // ALWAYS: the Nix spine (flake.nix + crabcc index drv + surface stub) and docs.
    try run(a, &files, &all_entries, try emitNixSpine(a, g, source_file));
    try run(a, &files, &all_entries, try emitDocsRuntime(a, g, source_file));

    // Direct: per-fiber Zig daemon configs.
    if (rv.fibers.len > 0) {
        try run(a, &files, &all_entries, try emitZigDaemoncfg(a, g, source_file, rv.fibers));
    }

    // Direct: catalog.jsonl for indexes that select it. (crabcc.index
    // provenance entries are produced inside emitNixSpine — the spine emitter
    // — so it is not run again here; catalog.sqlite is deferred.)
    {
        var jsonl_indexes: std.ArrayListUnmanaged(graphmod.GraphNode) = .empty;
        for (rv.indexes) |i| {
            if (hasTarget(try indexEmitTargets(a, i), "catalog.jsonl")) try jsonl_indexes.append(a, i);
        }
        if (jsonl_indexes.items.len > 0) {
            try run(a, &files, &all_entries, try emitCatalogJsonl(a, source_file, jsonl_indexes.items));
        }
    }

    // Track C (#19): the OTP supervision tree for `parallel … supervisor=otp`.
    {
        var otp_parallels: std.ArrayListUnmanaged(graphmod.GraphNode) = .empty;
        for (rv.parallels) |p| {
            const sup = refOf(getProp(p.props, "supervisor")) orelse continue;
            if (std.mem.eql(u8, sup, "otp")) try otp_parallels.append(a, p);
        }
        if (otp_parallels.items.len > 0) {
            try run(a, &files, &all_entries, try emitOtpSupervision(a, g, source_file, otp_parallels.items));
        }
    }

    // Direct: NixOS-deployment cohort (#1-#6), each gated on presence. The
    // order here is lower.py's `lower()` call order, which fixes the order
    // entries land in the flat list (and so their per-artifact order in the
    // manifest): secrets -> host_resources -> services -> ingresses ->
    // containers.
    if (rv.secrets.len > 0) {
        try run(a, &files, &all_entries, try emitSopsSecrets(a, source_file, rv.secrets));
    }
    if (rv.host_resources.len > 0) {
        try run(a, &files, &all_entries, try emitHostResources(a, source_file, rv.host_resources));
    }
    if (rv.services.len > 0) {
        try run(a, &files, &all_entries, try emitNixosService(a, g, source_file, rv.services));
    }
    if (rv.ingresses.len > 0) {
        try run(a, &files, &all_entries, try emitCaddyIngress(a, source_file, rv.ingresses));
    }
    if (rv.containers.len > 0) {
        try run(a, &files, &all_entries, try emitOciContainers(a, g, source_file, rv.containers));
    }

    // Runtime plane (#18/#24/#27): workflow specs + memory stores, plus the
    // per-runtime eventd log contract when EITHER consumer is present.
    if (rv.workflows.len > 0) {
        try run(a, &files, &all_entries, try emitWorkflowSpec(a, g, source_file, rv.workflows));
    }
    if (rv.memories.len > 0) {
        try run(a, &files, &all_entries, try emitMemoryStore(a, g, source_file, rv.memories));
    }
    if (rv.memories.len > 0 or rv.workflows.len > 0) {
        try run(a, &files, &all_entries, try emitEventdConfig(a, g, source_file));
    }

    // v0.5 trio: trust/quorum/probe topology, presence-gated like eventd.
    if (rv.trusts.len > 0 or rv.quorums.len > 0 or rv.probes.len > 0) {
        try run(a, &files, &all_entries, try emitTrustConfig(a, g, source_file));
    }

    // Network membrane (0012 §7): the compiled egress policy agent-guardd
    // loads, one per `network` decl. Inert when no membrane is declared.
    if (rv.networks.len > 0) {
        try run(a, &files, &all_entries, try emitEbpfPolicy(a, g, source_file, rv.networks));
    }

    // Deployment (#51): one colmena node per declared host.
    if (rv.hosts.len > 0) {
        try run(a, &files, &all_entries, try emitColmenaHive(a, g, source_file, rv.hosts));
    }

    const sorted_files = try files.toOwnedSlice(a);
    std.sort.block(File, sorted_files, {}, struct {
        fn less(_: void, x: File, y: File) bool {
            return std.mem.order(u8, x.path, y.path) == .lt;
        }
    }.less);

    const entries = try all_entries.toOwnedSlice(a);
    return LowerResult{
        .files = sorted_files,
        .provenance = try buildProvenance(a, source_file, entries),
        .entries = entries,
    };
}

fn emptyProvenance(a: Allocator, source_file: []const u8) Error!json.Value {
    const obj = try a.alloc(json.Value.Entry, 3);
    obj[0] = .{ .key = "version", .value = .{ .int = 1 } };
    obj[1] = .{ .key = "source", .value = .{ .string = source_file } };
    obj[2] = .{ .key = "artifacts", .value = .{ .object = &.{} } };
    return .{ .object = obj };
}

/// lower.py `_build_provenance` (0012 §6.2). The `artifacts` map is keyed
/// lexicographically by artifact path (code-point order == byte order for
/// UTF-8). The per-artifact entry list preserves the emitter's emission order.
/// `inputsHash` is a real, reproducible sha256 of each entry's projection.
pub fn buildProvenance(a: Allocator, source_file: []const u8, entries: []const ProvEntry) Error!json.Value {
    // Group by artifact, preserving first-seen order, then sort the keys.
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    for (entries) |e| {
        if (!containsStr(paths.items, e.artifact)) try paths.append(a, e.artifact);
    }
    const sorted_paths = try paths.toOwnedSlice(a);
    std.sort.block([]const u8, sorted_paths, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);

    const artifacts = try a.alloc(json.Value.Entry, sorted_paths.len);
    for (sorted_paths, 0..) |path, pi| {
        var out_entries: std.ArrayListUnmanaged(json.Value) = .empty;
        for (entries) |ent| {
            if (!std.mem.eql(u8, ent.artifact, path)) continue;
            // Field order IS the §6.2 emission order: [region?] sourceFile,
            // decl, span, emitter, inputsHash.
            var obj: std.ArrayListUnmanaged(json.Value.Entry) = .empty;
            if (ent.region) |r| try obj.append(a, .{ .key = "region", .value = .{ .string = r } });
            try obj.append(a, .{ .key = "sourceFile", .value = .{ .string = ent.source_file } });
            try obj.append(a, .{ .key = "decl", .value = .{ .string = ent.decl } });
            const sp = try a.alloc(json.Value.Entry, 5);
            sp[0] = .{ .key = "file", .value = .{ .string = ent.source_file } };
            sp[1] = .{ .key = "byteStart", .value = .{ .int = @intCast(ent.span.byte_start) } };
            sp[2] = .{ .key = "byteEnd", .value = .{ .int = @intCast(ent.span.byte_end) } };
            sp[3] = .{ .key = "line", .value = .{ .int = @intCast(ent.span.line) } };
            sp[4] = .{ .key = "col", .value = .{ .int = @intCast(ent.span.col) } };
            try obj.append(a, .{ .key = "span", .value = .{ .object = sp } });
            try obj.append(a, .{ .key = "emitter", .value = .{ .string = ent.emitter } });
            try obj.append(a, .{ .key = "inputsHash", .value = .{ .string = try inputsHash(a, ent.inputs_projection) } });
            try out_entries.append(a, .{ .object = try obj.toOwnedSlice(a) });
        }
        artifacts[pi] = .{ .key = path, .value = .{ .array = try out_entries.toOwnedSlice(a) } };
    }

    const doc = try a.alloc(json.Value.Entry, 3);
    doc[0] = .{ .key = "version", .value = .{ .int = 1 } };
    doc[1] = .{ .key = "source", .value = .{ .string = source_file } };
    doc[2] = .{ .key = "artifacts", .value = .{ .object = artifacts } };
    return .{ .object = doc };
}

// --------------------------------------------------------------------------- //
// Provenance manifest serialization (the exact §6.2 fixture layout).
// --------------------------------------------------------------------------- //
//
// The manifest is JSON, but with one deliberate readability convention that the
// `vaked/examples/lowering/provenance.json` fixture established and reviewers
// rely on: it is pretty-printed at a 2-space indent, EXCEPT each `span` object
// is rendered inline on a single line, so an entry reads as one decl + one
// compact source location. Standard `json.dumps(indent=2)` would explode every
// span across six lines, burying the attribution.

const span_key = "span";

/// `json.dumps(v, ensure_ascii=False)` for a scalar — identical to
/// `writeCanonical` for strings/ints/bools/null (compact, raw UTF-8).
fn jsonScalar(a: Allocator, v: json.Value) Error![]const u8 {
    return v.toOwned(a) catch error.OutOfMemory;
}

/// lower.py `_json_inline`: one line with `", "` / `": "` spacing (the `span`
/// object): `{ "file": "x", "byteStart": 27 }` / `[1, 2]`.
fn jsonInline(a: Allocator, v: json.Value) Error![]const u8 {
    switch (v) {
        .object => |obj| {
            if (obj.len == 0) return "{}";
            var parts: std.ArrayListUnmanaged([]const u8) = .empty;
            for (obj) |e| {
                try parts.append(a, try std.fmt.allocPrint(a, "{s}: {s}", .{
                    try jsonScalar(a, .{ .string = e.key }),
                    try jsonInline(a, e.value),
                }));
            }
            return std.fmt.allocPrint(a, "{{ {s} }}", .{try std.mem.join(a, ", ", parts.items)});
        },
        .array => |arr| {
            if (arr.len == 0) return "[]";
            var parts: std.ArrayListUnmanaged([]const u8) = .empty;
            for (arr) |x| try parts.append(a, try jsonInline(a, x));
            return std.fmt.allocPrint(a, "[{s}]", .{try std.mem.join(a, ", ", parts.items)});
        },
        else => return jsonScalar(a, v),
    }
}

/// lower.py `_json_pretty`: 2-space indent, but any `span` object inline.
/// Object keys keep insertion order (the §6.2 field order each entry was built
/// in); list items keep emission order.
fn jsonPretty(a: Allocator, v: json.Value, level: usize) Error![]const u8 {
    const pad = try repeatStr(a, "  ", level);
    const pad_in = try repeatStr(a, "  ", level + 1);
    switch (v) {
        .object => |obj| {
            if (obj.len == 0) return "{}";
            var parts: std.ArrayListUnmanaged([]const u8) = .empty;
            for (obj) |e| {
                const rendered = if (std.mem.eql(u8, e.key, span_key))
                    try jsonInline(a, e.value)
                else
                    try jsonPretty(a, e.value, level + 1);
                try parts.append(a, try std.fmt.allocPrint(a, "{s}{s}: {s}", .{
                    pad_in, try jsonScalar(a, .{ .string = e.key }), rendered,
                }));
            }
            return std.mem.concat(a, u8, &.{ "{\n", try std.mem.join(a, ",\n", parts.items), "\n", pad, "}" });
        },
        .array => |arr| {
            if (arr.len == 0) return "[]";
            var parts: std.ArrayListUnmanaged([]const u8) = .empty;
            for (arr) |x| {
                try parts.append(a, try std.mem.concat(a, u8, &.{ pad_in, try jsonPretty(a, x, level + 1) }));
            }
            return std.mem.concat(a, u8, &.{ "[\n", try std.mem.join(a, ",\n", parts.items), "\n", pad, "]" });
        },
        else => return jsonScalar(a, v),
    }
}

fn repeatStr(a: Allocator, s: []const u8, n: usize) Error![]const u8 {
    const out = try a.alloc(u8, s.len * n);
    var i: usize = 0;
    while (i < n) : (i += 1) @memcpy(out[i * s.len ..][0..s.len], s);
    return out;
}

/// lower.py `provenance_json_text`: the exact §6.2 fixture bytes — 2-space
/// indent, inline `span` objects, trailing newline. Pure and deterministic.
pub fn provenanceJsonText(a: Allocator, provenance_doc: json.Value) Error![]const u8 {
    return std.mem.concat(a, u8, &.{ try jsonPretty(a, provenance_doc, 0), "\n" });
}

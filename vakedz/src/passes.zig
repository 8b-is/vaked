// GENESIS_SEAL: 7c242080
//! vakedz.passes — the MLIR-mirror pass pipeline (port of `vakedc/passes/`,
//! byte-parity with `python3 -m vakedc passes --json`).
//!
//! Three passes, mirroring the Stage-1 MLIR dialect design (0021--0024):
//!
//!   Pass 1 — topology analysis   (0021, `pass01_topology.py`)  analysis-only
//!   Pass 2 — WAL injection       (0022, `pass02_wal.py`)       lowering
//!   Pass 3 — AOT supervisor index(0023, `pass03_aot_index.py`) codegen
//!
//! Pipeline contract (`vakedc/passes/__init__.py:60-96` `run_pipeline`): Pass 1
//! runs on every workflow node; IRs that produced a diagnostic are FAILING and
//! are excluded from Pass 2 and Pass 3 (0024 §2.1 — a topology-rejected IR gets
//! NO artifacts). `PassResult.workflows` is `clean ++ failing`, in that order —
//! NOT the input order. `PassResult.diagnostics` collects only failing IRs'
//! diagnostics.
//!
//! ## Python JSON settings being mirrored (`vakedc/__main__.py:301`)
//!
//!     sys.stdout.write(json.dumps(doc, ensure_ascii=False, indent=2) + "\n")
//!
//! i.e. `indent=2`; with a non-None `indent` Python's separators default to
//! `(",", ": ")` — the item separator loses its trailing space because Python
//! strips trailing whitespace from separators when indenting. `ensure_ascii=
//! False` is raw UTF-8 passthrough (exactly `lib.json.writeEscapedString`).
//! `sort_keys` is NOT set, so object key order is INSERTION order — the key
//! order below is fixed by `_cmd_passes`, not sorted. Empty containers render
//! as `[]` / `{}` with no inner newline. One trailing newline.
//!
//! `lib.json.Value.writeCanonical` is compact (no indent), so it cannot be
//! reused here; `writeIndented` below is this file's indent=2 writer. It shares
//! `lib.json.writeEscapedString`, so escaping cannot drift from emit.zig.
//!
//! ## Emitted document shape (`vakedc/__main__.py:282-300`)
//!
//! The `--json` document is the WHOLE observable contract (it is what
//! `tests/corpus/0024-differential/run_corpus.py` and `tools/vaked-cli`
//! `mlirValidate` decode):
//!
//!     {"workflows": [{"name","depth","criticalPath","steps","edges",
//!                     "walFrames"}],
//!      "diagnostics": [{"code","message"}],   // code+message ONLY — no span
//!      "artifacts": [<sorted path strings>],
//!      "status": "PASS"|"FAIL"}
//!
//! Note `diagnostics` carries NO span/file/severity, so the span machinery is
//! unobservable through this command; it is still populated faithfully on the
//! `Diagnostic` values for callers that want it.
//!
//! ## Number-literal trap
//!
//! Resolver props store number literals as STRINGS (`{"lit":"number","value":
//! "3"}` — `_coerce_number`). `maxDepth` is therefore parsed from a string, and
//! `depth` / `walFrames[].step` are computed `usize`s emitted as `.int` — never
//! round-tripped through the string props. See `maxDepthBound`.
//!
//! ## KNOWN DIVERGENCE — cycle-message rotation (vakedc bug)
//!
//! `pass01_topology.py:58` iterates cycle-detection DFS roots with
//! `for root in step_names`, where `step_names` is a **`set`**. Python's set
//! iteration order for strings depends on PYTHONHASHSEED, so the reported cycle
//! is an arbitrary ROTATION of the true cycle and vakedc's own output is not
//! reproducible run-to-run. Measured on
//! `tests/corpus/0024-differential/fixtures/cyclic.vaked`, all three rotations
//! occur across 12 seeds:
//!
//!     PYTHONHASHSEED=3  ->  "cycle: A -> B -> C -> A"
//!     PYTHONHASHSEED=0  ->  "cycle: B -> C -> A -> B"
//!     PYTHONHASHSEED=1  ->  "cycle: C -> A -> B -> C"
//!
//! Only the `message` rotates: the `code` (E-WORKFLOW-CYCLE), the diagnostic
//! COUNT, and every other field of the document are stable, which is why the
//! corpus harness (which asserts on `code`) never caught it. There is no single
//! Python behaviour to be bug-compatible WITH, so this port iterates roots in
//! `steps` DECLARATION order — deterministic, and equal to the Python output
//! whenever the seed happens to yield the declaration-order rotation. The
//! differential harness compares the cycle message modulo rotation for this
//! reason (`tools/passes-diff/run.sh`, CYCLE_ROTATION_TOLERANT).
//!
//! ## Pass 3 scope
//!
//! `AOTIndexGeneration.run` returns `{path: content}`; `_cmd_passes` emits only
//! `sorted(artifacts.keys())`, so CLI byte-parity needs only the KEY set. The
//! artifact CONTENT is `lower.py emit_workflow_spec` (`_emit_zig_json`,
//! `_header`, `_budget_prop`, `_Ordered`, ...), which is NOT yet ported to
//! `lower.zig` (it has `emitNixSpine` + `emitDocsRuntime` only). `aotIndex`
//! below therefore produces keys, and `PassResult.artifacts` is a path list
//! rather than a path->content map. This is a deliberate, documented gap, not
//! an approximation: every byte this command emits is exact. See
//! `aotIndex` for the re-entry point when `emit_workflow_spec` lands.
//!
//! Memory: everything is arena-allocated from the caller's allocator. No
//! process-exit and no IO here — that contract lives in main.zig.

const std = @import("std");
const lib = @import("lib");
const graphmod = lib.graph;
const json = lib.json;
const diag = lib.diagnostic;
const lower_mod = @import("lower.zig");

const Allocator = std.mem.Allocator;
pub const Error = error{OutOfMemory};

/// `passes/__init__.py:36-49` `WorkflowIR`. `diagnostics` is Python's
/// dynamically-attached `_diagnostics` attribute, made a real field here.
pub const WorkflowIR = struct {
    node: graphmod.GraphNode,
    steps: []const graphmod.GraphNode,
    edges: []const Edge,
    depth: usize = 0,
    critical_path: []const []const u8 = &.{},
    /// Pass 2 output.
    wal_frames: []const WalFrame = &.{},
    /// Pass 1 output (Python `ir._diagnostics`).
    diagnostics: []const diag.Diagnostic = &.{},
};

/// `(from_name, to_name)` — Python's `tuple[str, str]`.
pub const Edge = struct {
    from: []const u8,
    to: []const u8,
};

/// `pass02_wal.py:64-72`. Field order here IS the emitted key order (Python
/// dict insertion order); `wal`/`fetch`/`protocol` are constants in Stage 0.
pub const WalFrame = struct {
    producer: []const u8,
    consumer: []const u8,
    step: usize,
};

/// `passes/__init__.py:52-57` `PassResult`. `artifacts` is a sorted path list
/// rather than Python's `{path: content}` map — see the Pass 3 scope note in
/// the module doc.
pub const PassResult = struct {
    diagnostics: []const diag.Diagnostic = &.{},
    workflows: []const WorkflowIR = &.{},
    artifacts: []const []const u8 = &.{},
};

// ---------------------------------------------------------------------------
// Graph helpers — local ports of the `lower.py` helpers that `lower.zig` keeps
// private. Deliberately duplicated rather than exported from lower.zig: this
// slice owns passes.zig only, and these are the two smallest, most stable
// helpers in the file. TODO(passes-followup): collapse into lower.zig's
// `childrenOf`/`nodesSorted` if they are ever made `pub`.
// ---------------------------------------------------------------------------

/// lower.py `_children_of`: direct `contains` children in source order.
/// `g.edges` is insertion-ordered, which IS Python's adjacency-index order.
fn childrenOf(a: Allocator, g: *const graphmod.Graph, parent_id: []const u8) Error![]graphmod.GraphNode {
    var out: std.ArrayListUnmanaged(graphmod.GraphNode) = .empty;
    for (g.edges.items) |e| {
        if (!std.mem.eql(u8, e.label, "contains")) continue;
        if (!std.mem.eql(u8, e.source, parent_id)) continue;
        if (g.getNode(e.target)) |n| try out.append(a, n);
    }
    return out.toOwnedSlice(a);
}

/// `Graph.nodes_sorted()`: all nodes by id. The map is a StringHashMap, so its
/// iteration order is NONDETERMINISTIC — sorting here is what makes the
/// workflow roster (and therefore the whole document) reproducible.
pub fn nodesSorted(a: Allocator, g: *const graphmod.Graph) Error![]graphmod.GraphNode {
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

/// `__main__.py:274-275`: every `workflow` node, in id order.
pub fn workflowNodes(a: Allocator, g: *const graphmod.Graph) Error![]graphmod.GraphNode {
    const all = try nodesSorted(a, g);
    var out: std.ArrayListUnmanaged(graphmod.GraphNode) = .empty;
    for (all) |n| {
        if (std.mem.eql(u8, n.kind, "workflow")) try out.append(a, n);
    }
    return out.toOwnedSlice(a);
}

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

/// lower.py `_lit`: the literal value of a `{"lit": ..., "value": ...}` prop.
fn litOf(v: ?json.Value) ?[]const u8 {
    const val = v orelse return null;
    if (getProp(val, "lit") == null) return null;
    const value = getProp(val, "value") orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

/// lower.py `_workflow_steps_edges` (lower.py:2004-2012): a workflow's `node`
/// children in declaration order, and the `routes_to` edges among them as
/// (from_name, to_name). Edge order is `graph.edges` order — Python iterates
/// the same insertion-ordered list.
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
    for (step_slice) |s| try ids.put(a, s.id, s.name);

    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    for (g.edges.items) |e| {
        if (!std.mem.eql(u8, e.label, "routes_to")) continue;
        const from = ids.get(e.source) orelse continue;
        const to = ids.get(e.target) orelse continue;
        try edges.append(a, .{ .from = from, .to = to });
    }
    return .{ .steps = step_slice, .edges = try edges.toOwnedSlice(a) };
}

// ---------------------------------------------------------------------------
// Pass 1 — topology analysis (pass01_topology.py)
// ---------------------------------------------------------------------------

const Colour = enum(u2) { white, grey, black };

/// An insertion-ordered `name -> depth` memo. Python's `memo` is a dict, and
/// `_longest_path` picks its start with `max(memo, key=memo.get)`, which
/// returns the FIRST maximal entry in INSERTION order. A StringHashMap would
/// pick an arbitrary one, so insertion order is load-bearing here, not
/// incidental.
const Memo = struct {
    order: std.ArrayListUnmanaged([]const u8) = .empty,
    map: std.StringHashMapUnmanaged(usize) = .empty,

    fn get(self: *const Memo, name: []const u8) ?usize {
        return self.map.get(name);
    }

    fn put(self: *Memo, a: Allocator, name: []const u8, depth: usize) Error!void {
        if (!self.map.contains(name)) try self.order.append(a, name);
        try self.map.put(a, name, depth);
    }
};

/// Successor map: `name -> [names]`, built in `steps` order with successors in
/// edge order (Python `succ[a].append(b)`).
const Succ = struct {
    map: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty,

    fn get(self: *const Succ, name: []const u8) []const []const u8 {
        const l = self.map.get(name) orelse return &.{};
        return l.items;
    }
};

fn buildSucc(
    a: Allocator,
    steps: []const graphmod.GraphNode,
    edges: []const Edge,
) Error!Succ {
    var succ: Succ = .{};
    for (steps) |s| {
        if (!succ.map.contains(s.name)) {
            try succ.map.put(a, s.name, .empty);
        }
    }
    for (edges) |e| {
        // Python guards `if a in step_names and b in step_names`; stepsEdges
        // already resolved both endpoints to step names, but a workflow whose
        // step names collide can still miss, so the guard stays.
        const entry = succ.map.getPtr(e.from) orelse continue;
        if (!succ.map.contains(e.to)) continue;
        try entry.append(a, e.to);
    }
    return succ;
}

/// `pass01_topology.py:54-79` — iterative DFS with a colour map.
///
/// Root order: Python iterates the `step_names` SET (hash-seed dependent — see
/// the module doc). This iterates `steps` in declaration order instead, which
/// makes the reported rotation deterministic.
fn detectCycle(
    a: Allocator,
    steps: []const graphmod.GraphNode,
    succ: *const Succ,
) Error!?[]const []const u8 {
    var colour: std.StringHashMapUnmanaged(Colour) = .empty;
    for (steps) |s| try colour.put(a, s.name, .white);

    for (steps) |root_node| {
        const root = root_node.name;
        if ((colour.get(root) orelse .white) != .white) continue;

        // Each frame is a node plus its successor cursor (Python's `iter`).
        const Frame = struct { node: []const u8, i: usize };
        var stack: std.ArrayListUnmanaged(Frame) = .empty;
        var path: std.ArrayListUnmanaged([]const u8) = .empty;

        try colour.put(a, root, .grey);
        try stack.append(a, .{ .node = root, .i = 0 });
        try path.append(a, root);

        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const nexts = succ.get(top.node);
            var advanced = false;

            while (top.i < nexts.len) {
                const nxt = nexts[top.i];
                top.i += 1;
                switch (colour.get(nxt) orelse .white) {
                    .grey => {
                        // Python: `cycle = path[path.index(nxt):] + [nxt]`.
                        // `.index` is the FIRST occurrence — a grey node is on
                        // the current path exactly once, so first == only.
                        var idx: usize = 0;
                        while (idx < path.items.len) : (idx += 1) {
                            if (std.mem.eql(u8, path.items[idx], nxt)) break;
                        }
                        var cycle: std.ArrayListUnmanaged([]const u8) = .empty;
                        try cycle.appendSlice(a, path.items[idx..]);
                        try cycle.append(a, nxt);
                        return try cycle.toOwnedSlice(a);
                    },
                    .white => {
                        try colour.put(a, nxt, .grey);
                        try path.append(a, nxt);
                        try stack.append(a, .{ .node = nxt, .i = 0 });
                        advanced = true;
                        break;
                    },
                    .black => {},
                }
            }

            if (!advanced) {
                try colour.put(a, top.node, .black);
                _ = path.pop();
                _ = stack.pop();
            }
        }
    }
    return null;
}

/// `pass01_topology.py:96-99` — memoised critical-path depth. Recursive, like
/// Python; the graph is known acyclic here (detectCycle ran first), so this
/// terminates.
fn depthOf(a: Allocator, succ: *const Succ, memo: *Memo, name: []const u8) Error!usize {
    if (memo.get(name)) |d| return d;
    var best: usize = 0;
    for (succ.get(name)) |n| {
        const d = try depthOf(a, succ, memo, n);
        if (d > best) best = d;
    }
    const result = 1 + best;
    // Python assigns memo[name] AFTER the recursion, so successors are
    // inserted first. _longest_path's `max` tie-break depends on this order.
    try memo.put(a, name, result);
    return result;
}

/// `pass01_topology.py:132-147` `_longest_path`.
fn longestPath(a: Allocator, succ: *const Succ, memo: *const Memo) Error![]const []const u8 {
    if (memo.order.items.len == 0) return &.{};

    // Python `max(memo, key=memo.get)`: first maximal entry in insertion order.
    var start = memo.order.items[0];
    var best = memo.get(start).?;
    for (memo.order.items[1..]) |name| {
        const d = memo.get(name).?;
        if (d > best) {
            best = d;
            start = name;
        }
    }

    var path: std.ArrayListUnmanaged([]const u8) = .empty;
    try path.append(a, start);
    while (true) {
        const nexts = succ.get(start);
        if (nexts.len == 0) break;

        // Python: `nexts.sort(key=lambda x: -x[1])` then take [0] — a STABLE
        // sort, so ties keep successor order. std.sort.block is stable too;
        // scanning for the first strict maximum is equivalent and allocation
        // free.
        var pick = nexts[0];
        var pick_d = memo.get(pick) orelse 0;
        for (nexts[1..]) |n| {
            const d = memo.get(n) orelse 0;
            if (d > pick_d) {
                pick_d = d;
                pick = n;
            }
        }
        start = pick;
        try path.append(a, start);
    }
    return try path.toOwnedSlice(a);
}

/// `pass01_topology.py:107-124`: the declared `maxDepth` bound, or null when
/// absent / not an integer literal (Python swallows ValueError/TypeError —
/// "the type checker owns that error").
///
/// THE STRING TRAP: `maxDepth` arrives as `{"lit":"number","value":"3"}` —
/// `_lit` yields the STRING "3" and Python does `int(str(md_lit))`. A
/// non-integer literal (`3.5`, a string literal) raises and is swallowed.
fn maxDepthBound(wf: graphmod.GraphNode) ?i64 {
    const raw = getProp(wf.props, "maxDepth") orelse return null;
    const lit = litOf(raw) orelse return null;
    return std.fmt.parseInt(i64, lit, 10) catch null;
}

/// `pass01_topology.py:150-160` `_decl_span`.
fn declSpan(wf: graphmod.GraphNode) struct { line: usize, col: usize, byte_start: usize, byte_end: usize } {
    if (wf.provenance) |prov| {
        return .{
            .line = prov.span.line,
            .col = prov.span.col,
            .byte_start = prov.span.byte_start,
            .byte_end = prov.span.byte_end,
        };
    }
    return .{ .line = 0, .col = 0, .byte_start = 0, .byte_end = 0 };
}

/// `pass01_topology.py:39-129` `_analyse_one`.
fn analyseOne(
    a: Allocator,
    g: *const graphmod.Graph,
    wf: graphmod.GraphNode,
    source_file: []const u8,
) Error!WorkflowIR {
    const se = try stepsEdges(a, g, wf);
    const sp = declSpan(wf);
    var succ = try buildSucc(a, se.steps, se.edges);

    if (try detectCycle(a, se.steps, &succ)) |cycle| {
        var joined: std.ArrayListUnmanaged(u8) = .empty;
        for (cycle, 0..) |n, i| {
            if (i > 0) try joined.appendSlice(a, " -> ");
            try joined.appendSlice(a, n);
        }
        const msg = try std.fmt.allocPrint(
            a,
            "workflow `{s}` step edges must form a DAG; cycle: {s} " ++
                "(express revision loops as `retries` on a step, not back-edges)",
            .{ wf.name, joined.items },
        );
        const d = diag.Diagnostic{
            .code = "E-WORKFLOW-CYCLE",
            .message = msg,
            .file = source_file,
            .line = sp.line,
            .col = sp.col,
            .byte_start = sp.byte_start,
            .byte_end = sp.byte_end,
            .decl = try std.fmt.allocPrint(a, "workflow {s}", .{wf.name}),
            .severity = .@"error",
            .related = &.{},
        };
        const diags = try a.alloc(diag.Diagnostic, 1);
        diags[0] = d;
        // Python returns WorkflowIR(..., depth=0) with NO critical_path — the
        // cyclic workflow still appears in `workflows`, just empty-ish.
        return WorkflowIR{
            .node = wf,
            .steps = se.steps,
            .edges = se.edges,
            .depth = 0,
            .critical_path = &.{},
            .diagnostics = diags,
        };
    }

    var memo: Memo = .{};
    var depth: usize = 0;
    for (se.steps) |s| {
        const d = try depthOf(a, &succ, &memo, s.name);
        if (d > depth) depth = d;
    }
    const critical_path = try longestPath(a, &succ, &memo);

    var diags: std.ArrayListUnmanaged(diag.Diagnostic) = .empty;
    if (maxDepthBound(wf)) |bound| {
        // Compared in i64, NOT by casting `bound` to usize: Python's
        // `depth > bound` fires for a NEGATIVE bound (`maxDepth = -1` makes
        // every workflow exceed it), and a usize cast would either trap or
        // wrap that into a nonsense huge bound that never fires.
        if (@as(i64, @intCast(depth)) > bound) {
            try diags.append(a, .{
                .code = "E-WORKFLOW-DEPTH",
                .message = try std.fmt.allocPrint(
                    a,
                    "workflow `{s}` has critical-path depth {d}, " ++
                        "exceeding the declared maxDepth = {d}",
                    .{ wf.name, depth, bound },
                ),
                .file = source_file,
                .line = sp.line,
                .col = sp.col,
                .byte_start = sp.byte_start,
                .byte_end = sp.byte_end,
                .decl = try std.fmt.allocPrint(a, "workflow {s}", .{wf.name}),
                .severity = .@"error",
                .related = &.{},
            });
        }
    }

    return WorkflowIR{
        .node = wf,
        .steps = se.steps,
        .edges = se.edges,
        .depth = depth,
        .critical_path = critical_path,
        .diagnostics = try diags.toOwnedSlice(a),
    };
}

/// `pass01_topology.py:28-36` `TopologyAnalysis.run`.
pub fn topologyAnalysis(
    a: Allocator,
    g: *const graphmod.Graph,
    workflow_nodes: []const graphmod.GraphNode,
    source_file: []const u8,
) Error![]WorkflowIR {
    const out = try a.alloc(WorkflowIR, workflow_nodes.len);
    for (workflow_nodes, 0..) |wf, i| out[i] = try analyseOne(a, g, wf, source_file);
    return out;
}

// ---------------------------------------------------------------------------
// Pass 2 — WAL injection (pass02_wal.py)
// ---------------------------------------------------------------------------

/// `pass02_wal.py:44-75` `_inject_wal`: one frame per dependency edge.
fn injectWal(a: Allocator, wf: WorkflowIR) Error![]const WalFrame {
    // Python `{s.name: i for i, s in enumerate(wf.steps)}` — a dict
    // comprehension, so on a DUPLICATE step name the LAST index wins.
    var step_index: std.StringHashMapUnmanaged(usize) = .empty;
    for (wf.steps, 0..) |s, i| try step_index.put(a, s.name, i);

    const frames = try a.alloc(WalFrame, wf.edges.len);
    for (wf.edges, 0..) |e, i| {
        frames[i] = .{
            .producer = e.from,
            .consumer = e.to,
            // Python `step_index.get(from_name, 0)` — default 0.
            .step = step_index.get(e.from) orelse 0,
        };
    }
    return frames;
}

/// `pass02_wal.py:35-41` `WALInjection.run` — mutates the IRs in place.
pub fn walInjection(a: Allocator, workflows: []WorkflowIR) Error!void {
    for (workflows) |*wf| wf.wal_frames = try injectWal(a, wf.*);
}

// ---------------------------------------------------------------------------
// Pass 3 — AOT supervisor index (pass03_aot_index.py)
// ---------------------------------------------------------------------------

/// `pass03_aot_index.py:39-106` `AOTIndexGeneration.run`, KEYS ONLY.
///
/// Python returns `{path: content}`; `_cmd_passes` emits only
/// `sorted(artifacts.keys())`, so the CLI is byte-exact from the key set alone.
/// The content is `lower.py emit_workflow_spec`, which `lower.zig` has not
/// ported yet (see the Pass 3 scope note in the module doc).
///
/// TODO(passes-followup): when `lower.zig` grows `emitWorkflowSpec`, return
/// `[]const lower_mod.File` here and have `PassResult.artifacts` carry content;
/// the emitted `artifacts` array stays the sorted key list either way.
///
/// The `runtimeView(g) == null` early-out is the whole reason a graph with a
/// workflow but no `runtime` decl emits `"artifacts": []` — reproduced exactly.
pub fn aotIndex(
    a: Allocator,
    g: *const graphmod.Graph,
    workflows: []const WorkflowIR,
) Error![]const []const u8 {
    const rv = try lower_mod.runtimeView(a, g);
    if (rv == null) return &.{};

    // Python builds a dict keyed by path, so two workflows with the same name
    // collapse to one entry; a StringHashMap reproduces that, and the sort
    // below reproduces `sorted(...)` (byte order == Python's code-point order
    // for these ASCII paths).
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    for (workflows) |wf| {
        const path = try std.fmt.allocPrint(a, "gen/workflow/{s}.json", .{wf.node.name});
        if (seen.contains(path)) continue;
        try seen.put(a, path, {});
        try paths.append(a, path);
    }
    const slice = try paths.toOwnedSlice(a);
    std.sort.block([]const u8, slice, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);
    return slice;
}

// ---------------------------------------------------------------------------
// Pipeline
// ---------------------------------------------------------------------------

/// `passes/__init__.py:60-92` `run_pipeline`.
pub fn runPipeline(
    a: Allocator,
    g: *const graphmod.Graph,
    workflow_nodes: []const graphmod.GraphNode,
    source_file: []const u8,
) Error!PassResult {
    const irs = try topologyAnalysis(a, g, workflow_nodes, source_file);

    // Python partitions with two list comprehensions over `wf_irs`, so both
    // sides keep their relative input order.
    var clean: std.ArrayListUnmanaged(WorkflowIR) = .empty;
    var failing: std.ArrayListUnmanaged(WorkflowIR) = .empty;
    for (irs) |ir| {
        if (ir.diagnostics.len > 0) try failing.append(a, ir) else try clean.append(a, ir);
    }

    // Pass 2 + Pass 3 run ONLY on the clean IRs (0024 §2.1).
    try walInjection(a, clean.items);
    const artifacts = try aotIndex(a, g, clean.items);

    var diags: std.ArrayListUnmanaged(diag.Diagnostic) = .empty;
    for (failing.items) |wf| try diags.appendSlice(a, wf.diagnostics);

    // `workflows=clean + failing` — clean first, NOT input order.
    var all: std.ArrayListUnmanaged(WorkflowIR) = .empty;
    try all.appendSlice(a, clean.items);
    try all.appendSlice(a, failing.items);

    return PassResult{
        .diagnostics = try diags.toOwnedSlice(a),
        .workflows = try all.toOwnedSlice(a),
        .artifacts = artifacts,
    };
}

// ---------------------------------------------------------------------------
// JSON emission — `__main__.py:280-301`
// ---------------------------------------------------------------------------

/// Python `json.dumps(..., indent=2)`: newline + 2-space-per-level indent,
/// item separator "," (trailing space stripped under indent), key separator
/// ": ". Empty array/object emit as "[]"/"{}" with no inner newline.
fn writeIndented(v: json.Value, level: usize, writer: anytype) !void {
    switch (v) {
        .array => |arr| {
            if (arr.len == 0) return writer.writeAll("[]");
            try writer.writeAll("[\n");
            for (arr, 0..) |item, i| {
                if (i > 0) try writer.writeAll(",\n");
                try writer.splatByteAll(' ', (level + 1) * 2);
                try writeIndented(item, level + 1, writer);
            }
            try writer.writeByte('\n');
            try writer.splatByteAll(' ', level * 2);
            try writer.writeByte(']');
        },
        .object => |obj| {
            if (obj.len == 0) return writer.writeAll("{}");
            try writer.writeAll("{\n");
            for (obj, 0..) |e, i| {
                if (i > 0) try writer.writeAll(",\n");
                try writer.splatByteAll(' ', (level + 1) * 2);
                try json.writeEscapedString(e.key, writer);
                try writer.writeAll(": ");
                try writeIndented(e.value, level + 1, writer);
            }
            try writer.writeByte('\n');
            try writer.splatByteAll(' ', level * 2);
            try writer.writeByte('}');
        },
        // Scalars are indent-independent — reuse the canonical writer so number
        // and string formatting cannot drift from emit.zig.
        else => try v.writeCanonical(writer),
    }
}

fn strArray(a: Allocator, items: []const []const u8) Error!json.Value {
    const vals = try a.alloc(json.Value, items.len);
    for (items, 0..) |s, i| vals[i] = .{ .string = s };
    return .{ .array = vals };
}

/// The `--json` document of `__main__.py:282-300`. Key order is Python's
/// INSERTION order (no sort_keys) and is fixed by that literal.
pub fn resultToJson(a: Allocator, result: PassResult) Error!json.Value {
    const wfs = try a.alloc(json.Value, result.workflows.len);
    for (result.workflows, 0..) |wf, i| {
        const step_names = try a.alloc([]const u8, wf.steps.len);
        for (wf.steps, 0..) |s, j| step_names[j] = s.name;

        const edges = try a.alloc(json.Value, wf.edges.len);
        for (wf.edges, 0..) |e, j| {
            const pair = try a.alloc(json.Value.Entry, 2);
            pair[0] = .{ .key = "from", .value = .{ .string = e.from } };
            pair[1] = .{ .key = "to", .value = .{ .string = e.to } };
            edges[j] = .{ .object = pair };
        }

        const frames = try a.alloc(json.Value, wf.wal_frames.len);
        for (wf.wal_frames, 0..) |f, j| {
            // Key order == pass02_wal.py's dict literal order.
            const fields = try a.alloc(json.Value.Entry, 7);
            fields[0] = .{ .key = "type", .value = .{ .string = "DependencyRegistration" } };
            fields[1] = .{ .key = "producer", .value = .{ .string = f.producer } };
            fields[2] = .{ .key = "consumer", .value = .{ .string = f.consumer } };
            fields[3] = .{ .key = "step", .value = .{ .int = @intCast(f.step) } };
            fields[4] = .{ .key = "protocol", .value = .{ .string = "hcp.create_registration_token" } };
            fields[5] = .{ .key = "wal", .value = .{ .string = "hcp.write_ahead_log" } };
            fields[6] = .{ .key = "fetch", .value = .{ .string = "hcp.fetch_canonical_data" } };
            frames[j] = .{ .object = fields };
        }

        const entries = try a.alloc(json.Value.Entry, 6);
        entries[0] = .{ .key = "name", .value = .{ .string = wf.node.name } };
        entries[1] = .{ .key = "depth", .value = .{ .int = @intCast(wf.depth) } };
        entries[2] = .{ .key = "criticalPath", .value = try strArray(a, wf.critical_path) };
        entries[3] = .{ .key = "steps", .value = try strArray(a, step_names) };
        entries[4] = .{ .key = "edges", .value = .{ .array = edges } };
        entries[5] = .{ .key = "walFrames", .value = .{ .array = frames } };
        wfs[i] = .{ .object = entries };
    }

    const diags = try a.alloc(json.Value, result.diagnostics.len);
    for (result.diagnostics, 0..) |d, i| {
        // code + message ONLY — `_cmd_passes` emits no span/severity here.
        const entries = try a.alloc(json.Value.Entry, 2);
        entries[0] = .{ .key = "code", .value = .{ .string = d.code } };
        entries[1] = .{ .key = "message", .value = .{ .string = d.message } };
        diags[i] = .{ .object = entries };
    }

    const doc = try a.alloc(json.Value.Entry, 4);
    doc[0] = .{ .key = "workflows", .value = .{ .array = wfs } };
    doc[1] = .{ .key = "diagnostics", .value = .{ .array = diags } };
    doc[2] = .{ .key = "artifacts", .value = try strArray(a, result.artifacts) };
    doc[3] = .{ .key = "status", .value = .{
        .string = if (result.diagnostics.len > 0) "FAIL" else "PASS",
    } };
    return .{ .object = doc };
}

/// The exact bytes `python3 -m vakedc passes --json` writes to stdout,
/// trailing newline included.
pub fn resultToJsonText(a: Allocator, result: PassResult) Error![]u8 {
    const doc = try resultToJson(a, result);
    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    writeIndented(doc, 0, &aw.writer) catch return error.OutOfMemory;
    aw.writer.writeByte('\n') catch return error.OutOfMemory;
    return aw.toOwnedSlice() catch error.OutOfMemory;
}

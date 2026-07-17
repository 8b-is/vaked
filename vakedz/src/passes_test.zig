// GENESIS_SEAL: 7c242080
//! vakedz.passes tests — byte-parity of the pass pipeline against
//! `python3 -m vakedc passes --json`.
//!
//! The goldens below are the VERBATIM stdout of
//! `python3 -m vakedc passes --json tests/corpus/0024-differential/fixtures/<f>`,
//! captured from the Python reference. Those fixtures are the topology-class
//! oracle `tests/corpus/0024-differential/run_corpus.py` runs in CI
//! (`.github/workflows/corpus-0024.yml`), so matching them matches the real
//! consumer. The `--json` document carries no `file` field, so the goldens are
//! independent of the path the fixture is read from.
//!
//! Sources are byte-exact embedded copies of the fixture files (the established
//! lower_test.zig / emit_test.zig convention) so the tests stay hermetic — no
//! fixture IO from a unit test.
const std = @import("std");
const testing = std.testing;
const lex = @import("lexer.zig");
const parser = @import("parser.zig");
const resolve = @import("resolve.zig");
const passes = @import("passes.zig");

fn parseItems(a: std.mem.Allocator, src: []const u8) ![]const parser.Item {
    var l = lex.Lexer.init(a, src);
    try l.run();
    try testing.expectEqual(@as(usize, 0), l.errors.items.len);
    var p = parser.Parser.init(a, l.tokens.items);
    return p.parseFile();
}

/// The exact driver order of `vakedc passes` (`_cmd_passes`): parse_source ->
/// build_graph -> workflow nodes in id order -> run_pipeline. No checker.
fn passesJson(a: std.mem.Allocator, src: []const u8, filename: []const u8) ![]u8 {
    const items = try parseItems(a, src);
    var res = try resolve.buildGraph(a, items, filename);
    const wf_nodes = try passes.workflowNodes(a, &res.graph);
    const result = try passes.runPipeline(a, &res.graph, wf_nodes, filename);
    return passes.resultToJsonText(a, result);
}

fn expectGolden(src: []const u8, filename: []const u8, golden: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try passesJson(arena.allocator(), src, filename);
    try testing.expectEqualStrings(golden, got);
}

// --------------------------------------------------------------------------
// Fixture: single-agent.vaked — SINGLE NODE (no edges), depth 1.
// --------------------------------------------------------------------------

const single_agent_src =
    \\# single-agent.vaked — topology class: SINGLE NODE (no edges).
    \\# Exercises: the degenerate base case. Critical-path depth = 1.
    \\# Stage-0 must accept and lower. Stage-1 must produce an equivalent supervisor
    \\# index for one agent with no dependencies.
    \\runtime "single-agent" {
    \\  systems = ["x86_64-linux"]
    \\
    \\  mesh field {
    \\    node solo { role = "work" capabilities = [fs.repo_ro] }
    \\  }
    \\
    \\  workflow wf {
    \\    on = "e:created"
    \\    maxDepth = 1
    \\    node s1 { agent = field.solo }
    \\  }
    \\}
    \\
;

test "passes: single-agent fixture matches vakedc --json byte-for-byte" {
    try expectGolden(single_agent_src, "single-agent.vaked",
        \\{
        \\  "workflows": [
        \\    {
        \\      "name": "wf",
        \\      "depth": 1,
        \\      "criticalPath": [
        \\        "s1"
        \\      ],
        \\      "steps": [
        \\        "s1"
        \\      ],
        \\      "edges": [],
        \\      "walFrames": []
        \\    }
        \\  ],
        \\  "diagnostics": [],
        \\  "artifacts": [
        \\    "gen/workflow/wf.json"
        \\  ],
        \\  "status": "PASS"
        \\}
        \\
    );
}

// --------------------------------------------------------------------------
// Fixture: linear-chain.vaked — A -> B -> C, depth 3, 2 WAL frames.
// --------------------------------------------------------------------------

const linear_chain_src =
    \\# linear-chain.vaked — topology class: LINEAR CHAIN (A -> B -> C).
    \\# Exercises: a strict ordering with depth = 3 (counted in steps). Pass 1 must
    \\# compute depth identically across stages; Pass 3 must emit subscriptions in
    \\# source order.
    \\runtime "linear-chain" {
    \\  systems = ["x86_64-linux"]
    \\
    \\  mesh field {
    \\    node a { role = "work" capabilities = [fs.repo_ro] }
    \\  }
    \\
    \\  workflow wf {
    \\    on = "e:created"
    \\    maxDepth = 3
    \\    node A { agent = field.a }
    \\    node B { agent = field.a }
    \\    node C { agent = field.a }
    \\    A -> B -> C
    \\  }
    \\}
    \\
;

test "passes: linear-chain fixture matches vakedc --json byte-for-byte" {
    try expectGolden(linear_chain_src, "linear-chain.vaked",
        \\{
        \\  "workflows": [
        \\    {
        \\      "name": "wf",
        \\      "depth": 3,
        \\      "criticalPath": [
        \\        "A",
        \\        "B",
        \\        "C"
        \\      ],
        \\      "steps": [
        \\        "A",
        \\        "B",
        \\        "C"
        \\      ],
        \\      "edges": [
        \\        {
        \\          "from": "A",
        \\          "to": "B"
        \\        },
        \\        {
        \\          "from": "B",
        \\          "to": "C"
        \\        }
        \\      ],
        \\      "walFrames": [
        \\        {
        \\          "type": "DependencyRegistration",
        \\          "producer": "A",
        \\          "consumer": "B",
        \\          "step": 0,
        \\          "protocol": "hcp.create_registration_token",
        \\          "wal": "hcp.write_ahead_log",
        \\          "fetch": "hcp.fetch_canonical_data"
        \\        },
        \\        {
        \\          "type": "DependencyRegistration",
        \\          "producer": "B",
        \\          "consumer": "C",
        \\          "step": 1,
        \\          "protocol": "hcp.create_registration_token",
        \\          "wal": "hcp.write_ahead_log",
        \\          "fetch": "hcp.fetch_canonical_data"
        \\        }
        \\      ]
        \\    }
        \\  ],
        \\  "diagnostics": [],
        \\  "artifacts": [
        \\    "gen/workflow/wf.json"
        \\  ],
        \\  "status": "PASS"
        \\}
        \\
    );
}

// --------------------------------------------------------------------------
// Fixture: diamond.vaked — A -> {B, C} -> D. Exercises _longest_path's
// insertion-order tie-break: B and C both have depth 2, and Python's stable
// sort keeps B (successor order) — so criticalPath is A,B,D and NOT A,C,D.
// --------------------------------------------------------------------------

const diamond_src =
    \\# diamond.vaked — topology class: DIAMOND / FAN-IN (A -> B, A -> C, B -> D, C -> D).
    \\# Exercises: a non-trivial DAG where D has two predecessors. Critical-path
    \\# depth = 3 (A -> B -> D and A -> C -> D are equal length). Pass 1 must
    \\# de-duplicate the converging paths to a single depth; Pass 3 must record D's
    \\# two upstream subscriptions deterministically.
    \\runtime "diamond" {
    \\  systems = ["x86_64-linux"]
    \\
    \\  mesh field {
    \\    node a { role = "work" capabilities = [fs.repo_ro] }
    \\  }
    \\
    \\  workflow wf {
    \\    on = "e:created"
    \\    maxDepth = 3
    \\    node A { agent = field.a }
    \\    node B { agent = field.a }
    \\    node C { agent = field.a }
    \\    node D { agent = field.a }
    \\    A -> B
    \\    A -> C
    \\    B -> D
    \\    C -> D
    \\  }
    \\}
    \\
;

test "passes: diamond fixture matches vakedc --json byte-for-byte" {
    try expectGolden(diamond_src, "diamond.vaked",
        \\{
        \\  "workflows": [
        \\    {
        \\      "name": "wf",
        \\      "depth": 3,
        \\      "criticalPath": [
        \\        "A",
        \\        "B",
        \\        "D"
        \\      ],
        \\      "steps": [
        \\        "A",
        \\        "B",
        \\        "C",
        \\        "D"
        \\      ],
        \\      "edges": [
        \\        {
        \\          "from": "A",
        \\          "to": "B"
        \\        },
        \\        {
        \\          "from": "A",
        \\          "to": "C"
        \\        },
        \\        {
        \\          "from": "B",
        \\          "to": "D"
        \\        },
        \\        {
        \\          "from": "C",
        \\          "to": "D"
        \\        }
        \\      ],
        \\      "walFrames": [
        \\        {
        \\          "type": "DependencyRegistration",
        \\          "producer": "A",
        \\          "consumer": "B",
        \\          "step": 0,
        \\          "protocol": "hcp.create_registration_token",
        \\          "wal": "hcp.write_ahead_log",
        \\          "fetch": "hcp.fetch_canonical_data"
        \\        },
        \\        {
        \\          "type": "DependencyRegistration",
        \\          "producer": "A",
        \\          "consumer": "C",
        \\          "step": 0,
        \\          "protocol": "hcp.create_registration_token",
        \\          "wal": "hcp.write_ahead_log",
        \\          "fetch": "hcp.fetch_canonical_data"
        \\        },
        \\        {
        \\          "type": "DependencyRegistration",
        \\          "producer": "B",
        \\          "consumer": "D",
        \\          "step": 1,
        \\          "protocol": "hcp.create_registration_token",
        \\          "wal": "hcp.write_ahead_log",
        \\          "fetch": "hcp.fetch_canonical_data"
        \\        },
        \\        {
        \\          "type": "DependencyRegistration",
        \\          "producer": "C",
        \\          "consumer": "D",
        \\          "step": 2,
        \\          "protocol": "hcp.create_registration_token",
        \\          "wal": "hcp.write_ahead_log",
        \\          "fetch": "hcp.fetch_canonical_data"
        \\        }
        \\      ]
        \\    }
        \\  ],
        \\  "diagnostics": [],
        \\  "artifacts": [
        \\    "gen/workflow/wf.json"
        \\  ],
        \\  "status": "PASS"
        \\}
        \\
    );
}

// --------------------------------------------------------------------------
// Fixture: depth-bound-ok.vaked — depth == maxDepth. Boundary: `depth > bound`
// is strict, so equality must PASS.
// --------------------------------------------------------------------------

const depth_bound_ok_src =
    \\# depth-bound-ok.vaked — topology class: DEPTH-BOUND (boundary, accepting side).
    \\# Same shape as depth-bound-exceeded.vaked: a 3-step chain (depth = 3). Here
    \\# maxDepth is set EXACTLY at the actual depth, exercising the boundary of the
    \\# `depth > bound` check — depth == bound must pass. Stage-0 must lower clean.
    \\runtime "depth-bound-ok" {
    \\  systems = ["x86_64-linux"]
    \\
    \\  mesh field {
    \\    node a { role = "work" capabilities = [fs.repo_ro] }
    \\  }
    \\
    \\  workflow wf {
    \\    on = "e:created"
    \\    maxDepth = 3
    \\    node A { agent = field.a }
    \\    node B { agent = field.a }
    \\    node C { agent = field.a }
    \\    A -> B -> C
    \\  }
    \\}
    \\
;

test "passes: depth-bound-ok fixture — depth == maxDepth passes (strict >)" {
    try expectGolden(depth_bound_ok_src, "depth-bound-ok.vaked",
        \\{
        \\  "workflows": [
        \\    {
        \\      "name": "wf",
        \\      "depth": 3,
        \\      "criticalPath": [
        \\        "A",
        \\        "B",
        \\        "C"
        \\      ],
        \\      "steps": [
        \\        "A",
        \\        "B",
        \\        "C"
        \\      ],
        \\      "edges": [
        \\        {
        \\          "from": "A",
        \\          "to": "B"
        \\        },
        \\        {
        \\          "from": "B",
        \\          "to": "C"
        \\        }
        \\      ],
        \\      "walFrames": [
        \\        {
        \\          "type": "DependencyRegistration",
        \\          "producer": "A",
        \\          "consumer": "B",
        \\          "step": 0,
        \\          "protocol": "hcp.create_registration_token",
        \\          "wal": "hcp.write_ahead_log",
        \\          "fetch": "hcp.fetch_canonical_data"
        \\        },
        \\        {
        \\          "type": "DependencyRegistration",
        \\          "producer": "B",
        \\          "consumer": "C",
        \\          "step": 1,
        \\          "protocol": "hcp.create_registration_token",
        \\          "wal": "hcp.write_ahead_log",
        \\          "fetch": "hcp.fetch_canonical_data"
        \\        }
        \\      ]
        \\    }
        \\  ],
        \\  "diagnostics": [],
        \\  "artifacts": [
        \\    "gen/workflow/wf.json"
        \\  ],
        \\  "status": "PASS"
        \\}
        \\
    );
}

// --------------------------------------------------------------------------
// Fixture: depth-bound-exceeded.vaked — E-WORKFLOW-DEPTH.
//
// Pins the failing-IR contract (passes/__init__.py:69-81): the IR keeps its
// Pass-1 `depth` and `criticalPath` (the diagnostic is appended AFTER they are
// computed) but gets NO WAL frames and NO artifacts, because Pass 2 and Pass 3
// run only on clean IRs.
// --------------------------------------------------------------------------

const depth_bound_exceeded_src =
    \\# depth-bound-exceeded.vaked — topology class: DEPTH-BOUND (rejecting side).
    \\# Same shape as depth-bound-ok.vaked: a 3-step chain (depth = 3). Here maxDepth
    \\# is set BELOW the actual depth, so the critical-path bound is violated.
    \\# Stage-0 MUST reject with E-WORKFLOW-DEPTH (exit 1, no artifacts). Stage-1's
    \\# Pass 1 must reject the same input (soundness, §13.1).
    \\runtime "depth-bound-exceeded" {
    \\  systems = ["x86_64-linux"]
    \\
    \\  mesh field {
    \\    node a { role = "work" capabilities = [fs.repo_ro] }
    \\  }
    \\
    \\  workflow wf {
    \\    on = "e:created"
    \\    maxDepth = 2
    \\    node A { agent = field.a }
    \\    node B { agent = field.a }
    \\    node C { agent = field.a }
    \\    A -> B -> C
    \\  }
    \\}
    \\
;

test "passes: depth-bound-exceeded fixture — E-WORKFLOW-DEPTH, no WAL, no artifacts" {
    try expectGolden(depth_bound_exceeded_src, "depth-bound-exceeded.vaked",
        \\{
        \\  "workflows": [
        \\    {
        \\      "name": "wf",
        \\      "depth": 3,
        \\      "criticalPath": [
        \\        "A",
        \\        "B",
        \\        "C"
        \\      ],
        \\      "steps": [
        \\        "A",
        \\        "B",
        \\        "C"
        \\      ],
        \\      "edges": [
        \\        {
        \\          "from": "A",
        \\          "to": "B"
        \\        },
        \\        {
        \\          "from": "B",
        \\          "to": "C"
        \\        }
        \\      ],
        \\      "walFrames": []
        \\    }
        \\  ],
        \\  "diagnostics": [
        \\    {
        \\      "code": "E-WORKFLOW-DEPTH",
        \\      "message": "workflow `wf` has critical-path depth 3, exceeding the declared maxDepth = 2"
        \\    }
        \\  ],
        \\  "artifacts": [],
        \\  "status": "FAIL"
        \\}
        \\
    );
}

// --------------------------------------------------------------------------
// Fixture: cyclic.vaked — E-WORKFLOW-CYCLE.
//
// KNOWN DIVERGENCE (see passes.zig module doc): vakedc reports an arbitrary
// ROTATION of the cycle because `pass01_topology.py:58` iterates DFS roots over
// a `set`, whose order depends on PYTHONHASHSEED. The golden below is the
// declaration-order rotation, which vakedc emits under (e.g.) PYTHONHASHSEED=3
// and which this port always emits. Everything except the rotation of the names
// inside `message` is stable across seeds and asserted here exactly.
// --------------------------------------------------------------------------

const cyclic_src =
    \\# cyclic.vaked — topology class: CYCLE (illegal back-edge).
    \\# A 3-step chain plus a back-edge C -> A, forming a cycle. Workflow step edges
    \\# must form a DAG. Stage-0 MUST reject with E-WORKFLOW-CYCLE (exit 1, no
    \\# artifacts). Stage-1's Pass 1 cycle detector must reject the same input.
    \\runtime "cyclic" {
    \\  systems = ["x86_64-linux"]
    \\
    \\  mesh field {
    \\    node a { role = "work" capabilities = [fs.repo_ro] }
    \\  }
    \\
    \\  workflow wf {
    \\    on = "e:created"
    \\    maxDepth = 9
    \\    node A { agent = field.a }
    \\    node B { agent = field.a }
    \\    node C { agent = field.a }
    \\    A -> B -> C -> A
    \\  }
    \\}
    \\
;

test "passes: cyclic fixture — E-WORKFLOW-CYCLE, depth 0, no criticalPath" {
    try expectGolden(cyclic_src, "cyclic.vaked",
        \\{
        \\  "workflows": [
        \\    {
        \\      "name": "wf",
        \\      "depth": 0,
        \\      "criticalPath": [],
        \\      "steps": [
        \\        "A",
        \\        "B",
        \\        "C"
        \\      ],
        \\      "edges": [
        \\        {
        \\          "from": "A",
        \\          "to": "B"
        \\        },
        \\        {
        \\          "from": "B",
        \\          "to": "C"
        \\        },
        \\        {
        \\          "from": "C",
        \\          "to": "A"
        \\        }
        \\      ],
        \\      "walFrames": []
        \\    }
        \\  ],
        \\  "diagnostics": [
        \\    {
        \\      "code": "E-WORKFLOW-CYCLE",
        \\      "message": "workflow `wf` step edges must form a DAG; cycle: A -> B -> C -> A (express revision loops as `retries` on a step, not back-edges)"
        \\    }
        \\  ],
        \\  "artifacts": [],
        \\  "status": "FAIL"
        \\}
        \\
    );
}

// --------------------------------------------------------------------------
// Contract units — the traps the goldens alone would not localise.
// --------------------------------------------------------------------------

// `AOTIndexGeneration.run` early-outs when the graph declares no `runtime`
// (pass03_aot_index.py:47-49), so a workflow can be fully analysed yet emit an
// EMPTY artifacts list. 1 of the 56 examples is exactly this shape, so it is a
// real path, not a hypothetical.
test "passes: workflow without a runtime decl yields no artifacts" {
    const src =
        \\mesh field {
        \\  node a { role = "work" capabilities = [fs.repo_ro] }
        \\}
        \\
        \\workflow wf {
        \\  node A { agent = field.a }
        \\  node B { agent = field.a }
        \\  A -> B
        \\}
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = try parseItems(a, src);
    var res = try resolve.buildGraph(a, items, "t.vaked");
    const wf_nodes = try passes.workflowNodes(a, &res.graph);
    const result = try passes.runPipeline(a, &res.graph, wf_nodes, "t.vaked");

    try testing.expectEqual(@as(usize, 1), result.workflows.len);
    try testing.expectEqual(@as(usize, 2), result.workflows[0].depth);
    // Pass 1 + Pass 2 still ran — only Pass 3 short-circuited.
    try testing.expectEqual(@as(usize, 1), result.workflows[0].wal_frames.len);
    try testing.expectEqual(@as(usize, 0), result.artifacts.len);
    try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

// `maxDepth` arrives from the resolver as `{"lit":"number","value":"3"}` — the
// value is a STRING. A non-integer literal makes Python's `int()` raise, which
// `pass01_topology.py:123-124` SWALLOWS ("the type checker owns that error"),
// so no diagnostic is emitted even though the bound is unusable.
test "passes: non-integer maxDepth is swallowed, not diagnosed" {
    const src =
        \\runtime "r" {
        \\  systems = ["x86_64-linux"]
        \\  mesh field {
        \\    node a { role = "work" capabilities = [fs.repo_ro] }
        \\  }
        \\  workflow wf {
        \\    maxDepth = "not-a-number"
        \\    node A { agent = field.a }
        \\    node B { agent = field.a }
        \\    A -> B
        \\  }
        \\}
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = try parseItems(a, src);
    var res = try resolve.buildGraph(a, items, "t.vaked");
    const wf_nodes = try passes.workflowNodes(a, &res.graph);
    const result = try passes.runPipeline(a, &res.graph, wf_nodes, "t.vaked");

    try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try testing.expectEqual(@as(usize, 2), result.workflows[0].depth);
}

// `run_pipeline` returns `workflows=clean + failing` — NOT input order. With a
// failing workflow declared FIRST, the clean one must still come out first.
// Also pins that one workflow's cycle does not suppress another's artifact.
test "passes: workflows are ordered clean-then-failing, not input order" {
    const src =
        \\runtime "r" {
        \\  systems = ["x86_64-linux"]
        \\  mesh field {
        \\    node a { role = "work" capabilities = [fs.repo_ro] }
        \\  }
        \\  workflow bad {
        \\    node A { agent = field.a }
        \\    node B { agent = field.a }
        \\    A -> B -> A
        \\  }
        \\  workflow good {
        \\    node C { agent = field.a }
        \\  }
        \\}
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = try parseItems(a, src);
    var res = try resolve.buildGraph(a, items, "t.vaked");
    const wf_nodes = try passes.workflowNodes(a, &res.graph);
    const result = try passes.runPipeline(a, &res.graph, wf_nodes, "t.vaked");

    try testing.expectEqual(@as(usize, 2), result.workflows.len);
    try testing.expectEqualStrings("good", result.workflows[0].node.name);
    try testing.expectEqualStrings("bad", result.workflows[1].node.name);
    // Only the clean workflow gets an artifact.
    try testing.expectEqual(@as(usize, 1), result.artifacts.len);
    try testing.expectEqualStrings("gen/workflow/good.json", result.artifacts[0]);
    try testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    try testing.expectEqualStrings("E-WORKFLOW-CYCLE", result.diagnostics[0].code);
}

// A NEGATIVE maxDepth is a real diagnostic, not a no-op: Python's
// `if depth > bound` compares signed, so `maxDepth = -1` makes every workflow
// exceed its bound. Verified against the reference:
//
//   $ python3 -m vakedc passes --json neg.vaked
//   E-WORKFLOW-DEPTH: workflow `wf` has critical-path depth 1, exceeding the
//                     declared maxDepth = -1
//
// Regression pin: a `bound >= 0` guard (or a usize cast of `bound`) silently
// swallows this — the bound must be compared in i64.
test "passes: negative maxDepth still diagnoses (signed compare)" {
    const src =
        \\runtime "r" {
        \\  systems = ["x86_64-linux"]
        \\  mesh field {
        \\    node a { role = "work" capabilities = [fs.repo_ro] }
        \\  }
        \\  workflow wf {
        \\    maxDepth = -1
        \\    node A { agent = field.a }
        \\  }
        \\}
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = try parseItems(a, src);
    var res = try resolve.buildGraph(a, items, "t.vaked");
    const wf_nodes = try passes.workflowNodes(a, &res.graph);
    const result = try passes.runPipeline(a, &res.graph, wf_nodes, "t.vaked");

    try testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    try testing.expectEqualStrings("E-WORKFLOW-DEPTH", result.diagnostics[0].code);
    try testing.expectEqualStrings(
        "workflow `wf` has critical-path depth 1, exceeding the declared maxDepth = -1",
        result.diagnostics[0].message,
    );
}

// Python's `json.dumps(..., indent=2)` renders EMPTY containers as `[]`/`{}`
// with no inner newline, and uses `": "` / `,` separators. A graph with no
// workflows at all exercises every empty-container branch at once — this is
// the single most common shape in the corpus (43 of 62 files).
test "passes: empty document renders exactly like json.dumps(indent=2)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try passes.resultToJsonText(a, .{});
    try testing.expectEqualStrings(
        \\{
        \\  "workflows": [],
        \\  "diagnostics": [],
        \\  "artifacts": [],
        \\  "status": "PASS"
        \\}
        \\
    , text);
}

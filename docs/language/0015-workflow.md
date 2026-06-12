# 0015 — `workflow`: the typed agent-step DAG (swe_af)

Status: **design, schema + checking landed** (2026-06-12) · Series: language
design notes · Issue [#27](https://github.com/peterlodri-sec/vaked-base/issues/27)
· Epic [#17](https://github.com/peterlodri-sec/vaked-base/issues/17)

## Spark

The 1.0 daily-use target: a Nix-based agentfield-like system running **swe_af
workflows** — issue lands → plan → code → review → publish, each step executed
by an agent holding attenuated capabilities. `workflow` has been a grammar kind
since v0 (`operator-field.vaked` renders a `"workflow-dag"` view) but had no
schema, no example, no checking, no lowering. This note makes it a construct.

## The semantic split (the design's load-bearing decision)

Two graphs live in an agent system, and conflating them is how capability
models rot:

| Graph | Kind | Edge meaning | Check |
|-------|------|--------------|-------|
| **authority** | `mesh` | `a -> b` *delegates* capability (operator → agents) | attenuation, 0011 §4.4 (`E-CAP-ATTENUATION`) |
| **ordering** | `workflow` | `a -> b` *sequences* steps (plan → code) | DAG + depth (`E-WORKFLOW-CYCLE`, `E-WORKFLOW-DEPTH`) |

Agents are declared **once**, in the mesh, where the operator delegates each an
attenuated grant set (POLA). Workflow steps **reference** those agents
(`agent = field.coder`); they never carry authority themselves. A workflow can
therefore never widen what an agent may do — only ask it to act.

This split fell out of dogfooding: a naive `planner -> coder` workflow edge
inside a `mesh` is *rejected* by attenuation (the coder holds `fs.repo_rw`,
which the planner cannot delegate) — correctly, because that edge was never a
delegation. Ordering needed its own home.

## Surface (no grammar change)

The grammar's graph blocks (`node` + `->`) already express this; the work was
schema + checking. From
[`vaked/examples/agentfield-swe.vaked`](../../vaked/examples/agentfield-swe.vaked):

```vaked
workflow swe_af {
  on = "github.issue.labeled:agent"
  maxDepth = 6

  node plan    { agent = field.planner  output = artifacts.plan }
  node code    { agent = field.coder    input = artifacts.plan   output = artifacts.patch  retries = 2 }
  node review  { agent = field.reviewer input = artifacts.patch  output = artifacts.verdict }
  node publish { agent = field.broker   input = artifacts.verdict }

  plan -> code -> review -> publish
}
```

Schemas (normative copy in
[`parallel-types.md`](../../vaked/schema/parallel-types.md)): `workflow` is a
closed record (`on`, `budget`, `maxDepth`); each step body conforms to
`workflowStep` (`agent : MeshNode` required; `input`/`output`/`budget`/`retries`
optional; open).

## Checking (vakedc, landed with this note)

Implemented in `vakedc/check.py: _check_workflow`, mirroring `_check_mesh`:

1. **Step conformance** — each `node` body against `workflowStep`; a step
   without an `agent` is `E-CONFORM-MISSING-FIELD`.
2. **`E-WORKFLOW-CYCLE`** — `->` edges among declared steps must form a DAG
   (edges with an unknown endpoint are external and skipped, like mesh).
   Deterministic: at most one diagnostic, the first cycle in declaration order.
   Revision loops are `retries` on a step, **not** back-edges; a bounded-loop
   edge surface (`review -> plan : "revise" { max = 2 }`-style) is deferred —
   it needs the same conditional sub-language the backpressure deferral waits on.
3. **`E-WORKFLOW-DEPTH`** — with `maxDepth` declared, the longest step chain
   (counted in steps) must not exceed it.

(2) and (3) are **Stage-0 Pass 1** of the topology pipeline
([0013](./0013-mlir-topology-compilation.md) #23): the O(depth)
propagation-latency cascade and DAG property, enforced at check time over the
existing LPG — no MLIR dependency. These codes live here until folded into a
0011 revision (tracked on #27).

## Lowering (output-first; emitter deferred under #27)

| Artifact | Target |
|----------|--------|
| **supervisor workflow spec** | `gen/workflow/<name>.json` — steps, agent refs, edges, budgets, trigger — consumed by `agent-supervisord` (Track C, #19); a natural input to the AOT routing index (0013 Pass 3) |
| **eventd wiring** | step start/finish/retry events on the per-runtime log (#18) — a workflow run is a fold, so replay/rewind (#20) applies to runs for free |
| **docs** | the generated workflow DAG per runtime |

## Open

- Trigger vocabulary: `on` is a bare string selector today; a typed event
  source (relates to streams + the daemon-channel roster, #8) should replace it.
- Step budgets need the real `budget` schema (#28).
- Fan-in semantics (`a -> c`, `b -> c`): join behavior (all-of vs any-of) —
  deferred; today fan-in is permitted and unspecified, supervisord-defined.
- A step's `agent` ref is not yet resolution-enforced against the mesh (the
  `agent` field is not a data-flow ref; closed-world enforcement of
  `<mesh>.<node>` refs rides with #8 branch B).

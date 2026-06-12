# 0013 — MLIR topology compilation: the `vaked` + `hcp` dialects

Status: **design** (2026-06-12) · Series: language design notes · Issue
[#23](https://github.com/peterlodri-sec/vaked-base/issues/23) · Epic
[#17](https://github.com/peterlodri-sec/vaked-base/issues/17)

## Spark

> Using MLIR here is a phenomenal architectural choice, but with a specific
> caveat: we shouldn't use it to build the real-time runtime engine. Instead,
> we should use MLIR to construct a DSL and compiler pipeline that sits *above*
> our architecture.

Captured from an owner design session. The claim: model the multi-agent
dependency graph as custom MLIR dialects, run native compiler passes over the
topology, and ahead-of-time compile the `agent-supervisord` routing tables and
memory schemas — so the structural guarantees the runtime depends on are
enforced **before the code ever runs**.

This note adapts that proposal to repo reality and fixes its position in the
pipeline. The verdict it argues for:

| Question | Answer |
|----------|--------|
| Write `eventd` / the `memory` store / the daemons in MLIR? | **No.** Those are dynamic I/O systems (design: [eventd](../superpowers/specs/2026-06-12-eventd-design.md), [`memory` 0014](./0014-memory-primitive.md)). |
| Write the agent-topology definition language + optimizer as an MLIR pipeline? | **Yes — staged.** The *semantics* land now as passes over the existing LPG; the *MLIR dialects* land when we compile agent binaries. |

## Anchoring (source conversation → repo reality)

The source analysis referenced protocol artifacts that do not exist yet. The
real anchors:

| Source term | What it is here |
|-------------|-----------------|
| "RFC 0004 / RFC 0005" | Do not exist. The repo has RFCs [0001-hcp](../../protocol/rfcs/0001-hcp.md), [0002-hcplang](../../protocol/rfcs/0002-hcplang.md), [0003-litany-wire](../../protocol/rfcs/0003-litany-wire.md). The frames below need a **new HCP RFC** before the `hcp` dialect is normative (#23 checklist). |
| `DependencyRegistration` frame | A write-ahead "B depends on A's step-N output" registration — to be specified in that RFC, carried on the Litany wire, logged via `eventd`. |
| `rewind_scope` | A block vulnerable to upstream state drift — maps to the eventd fold + arena structural sharing (#16, #18) consumed by the Track D control plane (#20). |
| "MemPalace schemas" | The `memory` primitive ([0014](./0014-memory-primitive.md), #24). |
| "multi-agent dependency graph" | The **typed semantic graph** `vakedc` already produces (parse → check → lower). |

## 1. The two dialects

MLIR's power is nested abstractions ("dialects") progressively *lowered* into
one another. Two domain dialects:

### `vaked` dialect — high-level topology

Models the macro multi-agent dataflow graph: agents as structural ops, states
as dataflow values.

- `vaked.agent` — an agent boundary: its state schemas and execution logic.
- `vaked.consume` — agent B reading agent A's output. **This is the load-bearing
  op**: every cross-agent dependency becomes explicit dataflow.

### `hcp` dialect — low-level orchestration

Models the physical mechanics the protocol layer defines:

- `hcp.registration` — the write-ahead `DependencyRegistration` frame.
- `hcp.rewind_scope` — encapsulates code blocks vulnerable to state drift.

## 2. SSA use-def chains as agent dependency lineages

In MLIR, data flows through SSA values; use-def chains *are* the dependency
graph. In our world they mirror agent dependency lineages exactly:

```mlir
// High-level vaked dialect representing the agent graph
vaked.agent @agent_alpha {
  %step_15_out = vaked.execute_step() -> !vaked.state_hash
  vaked.yield %step_15_out
}

vaked.agent @agent_beta {
  // B consumes A's step-15 output
  %input_from_a = vaked.consume @agent_alpha : !vaked.state_hash

  // Downstream execution built on that input
  vaked.execute_with_dep(%input_from_a)
}
```

Because this is a strict mathematical graph, native compiler passes apply to
the agent topology. Note the structural rhyme with what Vaked already has: a
`mesh` block is `node`s + `->` edges; `fiber` input/output and `parallel`
`supervised-dag` already form the dataflow DAG in the LPG. The dialect is a
*serialization of the same typed semantic graph* — "syntax is the mask; the
graph is the face" holds here too.

## 3. The three passes (what the pipeline buys)

### Pass 1 — static DAG / critical-path analysis

Dependency cascades have O(depth) propagation latency. Compute the **critical
path** (longest dependency depth) of the whole network; if a declared bound is
exceeded — or a cycle exists where a DAG is required — **the build is rejected**
before a single agent is spawned. This is a checker-shaped property: it belongs
with the 0011 pipeline as a topology diagnostic (e.g. `E-TOPO-DEPTH`,
`E-TOPO-CYCLE`).

### Pass 2 — automatic dependency-registration insertion

Hand-writing write-ahead registration frames is error-prone. A lowering pass
intercepts every `vaked.consume` and injects the structural WAL sequence
immediately before the consumption:

```mlir
// Lowering: vaked.consume → explicit HCP actions
%token = hcp.create_registration_token(%producer, %step, %hash)
hcp.write_ahead_log(%token)            // write-ahead safety guarantee
%data  = hcp.fetch_canonical_data(%producer)
```

The WAL discipline becomes structural — generated, never hand-maintained.
(Frames per the new HCP RFC; the log is `eventd`, #18.)

### Pass 3 — AOT supervisor index generation

The compiler knows the static graph, so `agent-supervisord` need not build its
subscription map dynamically at runtime: compile the topology to a **read-only,
packed routing table** loaded at boot. Runtime index lookup becomes a flat-array
read instead of a hash-map insert. This is exactly an 0012-style artifact
(boring, inspectable, diffable) and lands with the OTP supervision lowering
(Track C, #19).

## 4. The unified pipeline

```text
 [ .vaked multi-agent source ]
             │
             ▼
   [ vaked dialect ]  ───→  graph optimization / depth + cycle analysis   (Pass 1)
             │
             ▼
    [ hcp dialect ]   ───→  auto-inject write-ahead registration frames   (Pass 2)
             │
             ▼
 [ lowering → LLVM / native ]
             │
             ▼
 [ compiled agent binaries + AOT supervisor index ]                       (Pass 3)
             │
             ▼
 [ agent-supervisord + eventd + memory ]      ← the runtime; NOT in MLIR
```

## 5. Staged adoption (the actual plan)

MLIR is a heavyweight C++ dependency; `vakedc` is deliberately a small,
deterministic front-end (soon a Zig port, #15). The *semantics* of the three
passes do not need MLIR — they need the typed graph, which exists today.

- **Stage 0 — now.** Implement the passes as LPG passes inside `vakedc`:
  the depth/cycle bound as a `check` diagnostic; registration-frame injection
  and the AOT supervisor index as 0012 emitters. Pure, total, hermetic —
  same graph ⇒ byte-identical artifacts, like every other emitter.
- **Stage 1 — with compiled agents.** Define the real `vaked`/`hcp` MLIR
  dialects and the progressive lowering (vaked → hcp → LLVM) when agent
  binaries are compiled ahead-of-time. That is the point where MLIR's pass
  infrastructure, verification, and codegen pay for their weight — and the
  Stage-0 passes become reference semantics for the dialect verifier.

What never moves into MLIR: `eventd`, the `memory` store, the Zig enforcement
daemons, the OTP control plane — dynamic I/O stays in the runtime, supervised,
with the compiler guaranteeing the topology it runs on.

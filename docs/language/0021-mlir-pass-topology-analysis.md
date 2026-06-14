---
doc: 0021
title: "MLIR Pass 1 — topology analysis (critical path, cycle, depth bound)"
status: Review
track: Language / MLIR
created: 2026-06-14
issue: 23
epic: 17
---

# 0021 — Pass 1: static topology analysis

Status: **Review** (2026-06-14) · Series: language design notes · Track:
**Language / MLIR** · Issue
[#23](https://github.com/peterlodri-sec/vaked-base/issues/23) · Epic
[#17](https://github.com/peterlodri-sec/vaked-base/issues/17)

Part of the MLIR set; umbrella in
[0013](./0013-mlir-topology-compilation.md). **Stage-0 reference semantics:**
`vakedc/check.py` (`_check_workflow`) and `vakedc/lower.py` (`_workflow_depth`),
specified for the language in [0015](./0015-workflow.md). **Protocol anchor:**
[RFC 0004](../../protocol/rfcs/0004-multi-agent-state-dependency.md) §5
(`VerifyStateDependencyDAG`).

## Abstract

Pass 1 runs over the `vaked` dialect ([0019](./0019-mlir-vaked-dialect.md)). It
builds the **state-dependency subgraph** from the `vaked.consume` edges, rejects
the build on a forbidden cycle, computes the **critical path** (longest
dependency depth), and rejects the build when a declared depth bound is
exceeded — all before any agent is spawned. This part also **reconciles the
three diagnostic names** the codebase and RFCs currently use for these two
failures into one canonical pair.

## 1. Input and the graph it builds

Pass 1 reads a verified `vaked` module and builds a directed graph `G`:

- **Nodes** — every `vaked.agent` (by `sym_name`).
- **Edges** — one `producer → consumer` edge per `vaked.consume` op, where
  `consumer` is the enclosing `vaked.agent` and `producer` is the op's resolved
  `producer` symbol (V-CONSUME, [0019](./0019-mlir-vaked-dialect.md) §2.3).

`G` is precisely the `state_dependency` subgraph of RFC 0004 §5 — observation,
control-signal, and metrics edges are not `vaked.consume` and never enter it, so
feedback loops on those axes remain legal.

## 2. The two analyses

### 2.1 Cycle analysis (DAG enforcement)

> The state-dependency subgraph MUST be acyclic per topology epoch (RFC 0004 §5).

On a cycle, **the build is rejected** with a single deterministic diagnostic
naming the cycle path. Determinism matches Stage 0: iterate agents in module
order, run a coloured DFS (`WHITE/GREY/BLACK`), report the **first** back-edge
reached — the exact algorithm in `vakedc/check.py` `_check_workflow`. Revision
loops are expressed as step `retries`, never as a back-edge (0015).

### 2.2 Critical-path / depth bound

Dependency cascades have O(depth) propagation latency. Pass 1 computes the
**longest chain in `G`, counted in agents/steps** — the memoized longest-path
recurrence of `vakedc/lower.py` `_workflow_depth`:

```text
depth(n) = 1 + max(depth(s) for s in successors(n)),  default 0
critical_path = max(depth(n) for n in G)
```

When a depth bound is declared (`maxDepth` on the `workflow`/agent record), a
critical path exceeding it **rejects the build**. The computed per-node depth is
annotated onto each `vaked.agent` (a `depth` attribute) and carried into Pass 3
([0023](./0023-mlir-pass-aot-supervisor-index.md)), which is why this analysis
runs first.

## 3. Diagnostic naming — the reconciliation (normative)

Three names exist in the tree for these two failures. This section is their
single source of truth.

| Failure | Shipped (canonical) | Also seen as | Retired |
|---------|---------------------|--------------|---------|
| state-dependency cycle | **`E-WORKFLOW-CYCLE`** — `vakedc/check.py`, [0015](./0015-workflow.md) | `E-TOPO-CYCLE` (0013 sketch); `E-CYCLE-DETECTED` (RFC 0004 §5.1 algorithm) | the latter two |
| depth bound exceeded | **`E-WORKFLOW-DEPTH`** — `vakedc/check.py`, [0015](./0015-workflow.md) | `E-TOPO-DEPTH` (0013 sketch) | `E-TOPO-DEPTH` |

**Decision.** The canonical codes are the **shipped** `E-WORKFLOW-CYCLE` and
`E-WORKFLOW-DEPTH`. Rationale: they are emitted by the running checker and cited
in 0015; forking a parallel `E-TOPO-*` / `E-CYCLE-DETECTED` namespace for the
identical property would split diagnostics across two names for one bug. When
Pass 1 generalizes from `workflow` step edges to *all* `state_dependency` edges
(mesh / fiber / parallel agents), the **same two codes apply** — `workflow` is
simply the first edge class to reach the pass. RFC 0004 §5.1's `E-CYCLE-DETECTED`
and the 0013 `E-TOPO-*` sketch are hereby aliases of the canonical pair and
should be updated to it on next edit (tracked under #27).

> Implementation note: a future 0011 revision may host these codes under a
> topology-neutral spelling; until then the `E-WORKFLOW-*` codes own them and no
> new code is minted.

## 4. Pre/postconditions (the pass contract)

**Preconditions**
- The module passes the `vaked` dialect verifier ([0019](./0019-mlir-vaked-dialect.md));
  in particular every `vaked.consume.producer` resolves.

**Postcondition — success**
- `G` is acyclic and `critical_path ≤ maxDepth` (when declared).
- Each `vaked.agent` is annotated with its `depth`; the module is unchanged
  otherwise (Pass 1 is analysis + annotation, not rewrite — rewriting is Pass 2).

**Postcondition — failure**
- Exactly one diagnostic, `E-WORKFLOW-CYCLE` (with the cycle path) or
  `E-WORKFLOW-DEPTH` (with `critical_path` and the bound); the build stops. On a
  cycle, depth is **undefined and not reported** (matches `_check_workflow`,
  which returns before the depth check on a cyclic graph).

## 5. Stage-0 fidelity

The Stage-1 pass MUST produce the **same verdict** as the shipped Stage-0 check
on every graph ([0024](./0024-mlir-lowering-staged-adoption.md) §4):

| Pass 1 (Stage 1) | Stage 0 |
|------------------|---------|
| cycle detection, first back-edge in module order | `_check_workflow` coloured-DFS, `E-WORKFLOW-CYCLE` |
| longest-chain depth, counted in steps | `_workflow_depth` memoized recurrence |
| `critical_path > maxDepth` → reject | `_check_workflow` `E-WORKFLOW-DEPTH` (depth vs `maxDepth`) |

A divergence between the MLIR pass and these functions is a **bug in the pass**,
not a spec freedom — Stage 0 is authoritative until Stage 1 ships and is proven
equivalent.

## Security considerations

- **Fail-closed.** A graph Pass 1 cannot fully analyze (e.g. an unresolved
  producer that slipped the verifier) MUST reject, never warn-and-continue — an
  un-analyzed topology is one whose acyclicity is unproven (RFC 0004's reason
  for the invariant: prevent state-consumption deadlock).
- **Determinism is a review property.** A single, order-stable diagnostic means
  the same source always fails the same way, so a reviewer can trust a green
  Pass 1 and diff a red one.

## Open questions

- Generalizing `G` beyond `workflow` edges to mesh/fiber/parallel
  `state_dependency` edges (RFC 0004 §5's full edge-kind taxonomy) — staged with
  those kinds' Stage-0 checks; the diagnostic codes (§3) are already fixed for
  it.
- Whether the per-node `depth` annotation should also carry the critical-path
  *witness* (the longest chain itself) for Pass 3 diagnostics — non-gating.

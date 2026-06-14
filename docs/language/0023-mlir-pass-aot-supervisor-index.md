---
doc: 0023
title: "MLIR Pass 3 — AOT supervisor index generation"
status: Review
track: Language / MLIR
created: 2026-06-14
issue: 23
epic: 17
---

# 0023 — Pass 3: AOT supervisor index generation

Status: **Review** (2026-06-14) · Series: language design notes · Track:
**Language / MLIR** · Issue
[#23](https://github.com/peterlodri-sec/vaked-base/issues/23) · Epic
[#17](https://github.com/peterlodri-sec/vaked-base/issues/17)

Part of the MLIR set; umbrella in
[0013](./0013-mlir-topology-compilation.md). **Stage-0 reference:**
`vakedc/lower.py` (`emit_workflow_spec`, `_workflow_depth`) emitting
`gen/workflow/<name>.json`. **Protocol anchor:**
[RFC 0004](../../protocol/rfcs/0004-multi-agent-state-dependency.md) §8 (impl
order, item 4: the O(1) dependency lookup index) and §6 (boot sequence).

## Abstract

The compiler knows the entire static dependency graph, so `agent-supervisord`
need not build its subscription/routing map dynamically at boot. Pass 3 emits a
**packed, read-only routing table** — the supervisor index — loaded at boot,
turning a runtime hash-map insert into a flat-array read. It is a `0012`-style
artifact: pure, total, hermetic, inspectable, diffable.

## 1. What the index contains

Computed from the post-Pass-2 module plus the per-agent `depth` annotation Pass 1
attached ([0021](./0021-mlir-pass-topology-analysis.md) §2.2):

| Field | Source | Used by `agent-supervisord` for |
|-------|--------|---------------------------------|
| agent roster (boot order) | `vaked.agent` symbols, toposorted | spawn order (producers before consumers) |
| subscription map | `vaked.consume` edges (producer → consumers) | routing a producer's step output to its consumers |
| anchor table | each `hcp.create_registration_token` `(producer, producer_step, topology_epoch)` | O(1) dependency lookup for rewind matching (RFC 0004 §8 item 4) |
| critical-path depth | Pass 1 `depth` annotation | scheduling / latency budgeting |
| eventd log binding | runtime view (the `log` path) | where step events append (RFC 0004) |

## 2. Why AOT

Runtime index *construction* is work the static graph already determines.
Building it at boot means every supervisor re-derives the same map and risks
divergence; compiling it means one canonical table, diffable in review, loaded
as a flat read. This is the `0012` philosophy applied to the routing layer —
"boring, inspectable, diffable" — and it lands with the OTP supervision lowering
(Track C, #19).

## 3. Pre/postconditions (the pass contract)

**Preconditions**
- Pass 1 succeeded (depth annotations present; graph acyclic).
- Pass 2 succeeded (no `vaked.consume` remains; anchors materialized as
  `hcp.create_registration_token` ops, [0022](./0022-mlir-pass-wal-injection.md)).

**Postconditions**
- One packed index per runtime, deterministic: same module ⇒ byte-identical
  table (the `0012` purity contract).
- The index is **read-only** at runtime — `agent-supervisord` loads, never
  mutates it; topology changes bump the topology epoch (RFC 0004 §7) and
  **recompile** the index, they do not patch it live.
- Every anchor-table entry carries its `topology_epoch`, so the boot-time
  cold-start verifier (RFC 0004 §6) can reject a stale-epoch anchor.

## 4. Stage-0 fidelity

Stage 0 already emits this index, as JSON. `vakedc/lower.py` `emit_workflow_spec`
writes `gen/workflow/<name>.json` — "the AOT spec `agent-supervisord` loads at
boot" — carrying the step roster, the DAG `edges` (the subscription map), the
eventd `log` binding, and the **precomputed critical-path `depth`** via
`_workflow_depth` (commented in `lower.py` as the "0013 Pass-1 output"). The
Stage-1 pass MUST emit a table that agrees with this spec
([0024](./0024-mlir-lowering-staged-adoption.md) §4): same roster, same edges,
same depth. The packed binary layout is a Stage-1 optimization over the Stage-0
JSON; the *contents* are fixed by the Stage-0 emitter.

| Pass 3 (Stage 1) | Stage 0 (`gen/workflow/<name>.json`) |
|------------------|--------------------------------------|
| subscription map | `edges` (`{from, to}` over steps) |
| critical-path depth | `depth` (from `_workflow_depth`) |
| eventd log binding | `log` (`_eventd_log_path`) |
| agent roster + boot order | `steps` (declaration order, toposort-consistent) |

## Security considerations

- **Read-only is integrity.** A mutable boot index would let a compromised
  supervisor silently re-route a producer's output to an unintended consumer.
  The compile-time table + epoch-bumped recompile (§3) keeps routing authority
  in the artifact, where it is diffable, not in live process state.
- **Diffability is the audit.** Because the index is a pure function of the
  graph, an unexpected diff in the committed/emitted table is a topology change
  someone must justify — the same property that makes `0012` artifacts
  reviewable.

## Open questions

- Packed binary layout (Stage 1): vendor a fixed little-endian flat-array
  encoding, or reuse the content-addressed arena layout (#16)? Non-gating; the
  Stage-0 JSON is the interim format.
- Whether the anchor table should pre-materialize the transitive closure for
  the §6 transitive-verification path, or keep only direct edges and let the
  verifier walk them — trade table size against cold-start latency.

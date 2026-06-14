---
doc: 0024
title: "MLIR lowering contract + staged adoption + reference semantics"
status: Review
track: Language / MLIR
created: 2026-06-14
issue: 23
epic: 17
---

# 0024 — Lowering, staged adoption, and the reference-semantics contract

Status: **Review** (2026-06-14) · Series: language design notes · Track:
**Language / MLIR** · Issue
[#23](https://github.com/peterlodri-sec/vaked-base/issues/23) · Epic
[#17](https://github.com/peterlodri-sec/vaked-base/issues/17)

Part of the MLIR set; umbrella in
[0013](./0013-mlir-topology-compilation.md). **Stage-0 reference semantics:**
`vakedc/check.py` and `vakedc/lower.py`.

## Abstract

This part closes the set. It specifies the **progressive lowering contract**
(`vaked → hcp → LLVM`), draws the **Stage 0 / Stage 1** line and what gates the
transition, fixes **what never enters MLIR**, and states the **reference-semantics
contract**: the shipped Stage-0 passes are the authoritative definition of the
pipeline's behavior, and the Stage-1 dialects + passes are correct iff they
agree with them on every graph.

## 1. The lowering contract

```text
 vaked dialect ──Pass 1 (analyze)──▶ vaked (annotated: depth, acyclic)
       │
       └──Pass 2 (vaked→hcp)──▶ hcp dialect (WAL sequences, rewind scopes)
                                     │
                                     ├──Pass 3──▶ AOT supervisor index (0023)
                                     │
                                     └──hcp→LLVM──▶ compiled agent binaries
```

Progressive lowering, MLIR-idiomatic: each stage is a dialect whose verifier
holds before the next pass runs. Pass 1 ([0021](./0021-mlir-pass-topology-analysis.md))
analyzes and annotates `vaked`; Pass 2 ([0022](./0022-mlir-pass-wal-injection.md))
rewrites `vaked → hcp`; Pass 3 ([0023](./0023-mlir-pass-aot-supervisor-index.md))
reads the `hcp` module to emit the index; the final `hcp → LLVM` lowering is the
agent-binary codegen that *only Stage 1 performs* (§2).

## 2. Stage 0 vs Stage 1

| | Stage 0 — **now** | Stage 1 — **deferred** |
|---|---|---|
| Substrate | the typed graph (LPG) in `vakedc` | the real `vaked`/`hcp` MLIR dialects |
| Pass 1 | `vakedc/check.py` `_check_workflow` (`E-WORKFLOW-CYCLE/DEPTH`) | MLIR analysis pass ([0021](./0021-mlir-pass-topology-analysis.md)) |
| Pass 2 | edge + eventd-log wiring in `gen/workflow/<name>.json` (runtime does WAL) | explicit `hcp` WAL sequence ([0022](./0022-mlir-pass-wal-injection.md)) |
| Pass 3 | `vakedc/lower.py` `emit_workflow_spec` JSON | packed binary index ([0023](./0023-mlir-pass-aot-supervisor-index.md)) |
| `hcp → LLVM` | — (no compiled agent binaries yet) | agent-binary codegen |

**What gates Stage 1.** MLIR is a heavyweight C++ dependency; `vakedc` is a
small, deterministic front-end (soon a Zig port, #15). Stage 1 is justified only
when **agent binaries are compiled ahead-of-time** — that is the point where
MLIR's pass infrastructure, verification, and codegen pay for their weight.
Until then the dialects are specified (this set) but unbuilt, and the Stage-0
passes run the pipeline.

## 3. What never enters MLIR

MLIR compiles the **topology**, not the runtime that runs on it. These stay
dynamic, supervised I/O — outside every dialect and pass in this set:

| System | Why not MLIR | Design |
|--------|--------------|--------|
| `eventd` | append-only, hash-chained runtime log — dynamic I/O | [eventd design](../superpowers/specs/2026-06-12-eventd-design.md) |
| `memory` store | runtime-accumulated, mined, replayable | [0014](./0014-memory-primitive.md) |
| Zig enforcement daemons | runtime membranes (eBPF/network) | `daemons/` roster |
| OTP control plane | live supervision / lifecycle transitions | RFC 0004 §6 (`agent-supervisord`) |
| `ConsumerCheckpoint` / GC floor | runtime checkpoint + compaction state | RFC 0004 §4 (see [0020](./0020-mlir-hcp-dialect.md) §1) |

The compiler **guarantees the topology** these systems run on; it does not
become them. This is the original Spark's caveat, made normative: use MLIR to
build the DSL + compiler pipeline that sits *above* the architecture, not the
real-time runtime engine.

## 4. The reference-semantics contract (normative)

Until Stage 1 ships and is proven equivalent, **the Stage-0 passes are the
definition of the pipeline's behavior.** The Stage-1 dialects + passes are
*correct* iff, for every input graph, they produce the verdict and artifacts the
Stage-0 functions produce. The obligations, gathered from each part's "Stage-0
fidelity" section:

| Obligation | Stage-1 surface | Stage-0 authority |
|------------|-----------------|-------------------|
| **O1 — edge set** | the `state_dependency` edges Pass 1 builds from `vaked.consume` | the `workflow` `->` edges (`_check_workflow`); no edge added or dropped |
| **O2 — cycle verdict** | Pass 1 `E-WORKFLOW-CYCLE`, first back-edge, module order | `_check_workflow` coloured DFS |
| **O3 — depth** | Pass 1 critical path; `E-WORKFLOW-DEPTH` vs `maxDepth` | `_workflow_depth` recurrence + the `maxDepth` check |
| **O4 — WAL binding** | per-consume `create→write_ahead→fetch` (V-WAL-ORDER) | the `edges` + eventd `log` of `emit_workflow_spec` |
| **O5 — index contents** | Pass 3 roster / subscription / depth / log | the `steps` / `edges` / `depth` / `log` of `gen/workflow/<name>.json` |
| **O6 — determinism** | byte-identical output per input module | the `0012` purity contract (same graph ⇒ byte-identical artifacts) |

A Stage-1 result that diverges from O1–O6 is a **bug in Stage 1**, not a license
to change the contract. When Stage 1 lands, an equivalence test harness (run the
LPG passes and the MLIR passes over a corpus of `.vaked` graphs and diff the
verdicts + artifacts) is the acceptance gate; only after it is green does the
authority shift from `vakedc` to the dialect verifier.

## Security considerations

- **The contract is the anti-drift mechanism.** Two implementations of one
  semantics drift unless one is authoritative. Pinning authority to the shipped,
  deterministic Stage-0 passes means a Stage-1 dialect can never *weaken* a
  guarantee (drop an edge, miss a cycle, skip a registration) without the
  equivalence harness going red.
- **Scope discipline is a security property.** §3's exclusions keep the
  runtime's dynamic trust decisions (compaction, eviction, lifecycle) out of the
  compiler, which cannot observe live lease/heartbeat state (RFC 0004 §4) — the
  compiler must not appear to authorize what it cannot see.

## Open questions

- The equivalence harness (§4): does it live in `vakedc`'s test suite or as a
  standalone Stage-1 acceptance tool? Decide when Stage 1 starts (#15/#17).
- Whether any Stage-0 pass should be *frozen* (no further semantic change) once
  it becomes a reference, to stop the authority moving under Stage 1 mid-build.
- The `hcp → LLVM` agent-binary ABI is entirely open — it is Stage 1's first
  real design task and intentionally unspecified here (this set stops at the
  dialects + the three topology passes).

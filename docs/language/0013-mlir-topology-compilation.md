---
doc: 0013
title: "MLIR topology compilation — the vaked + hcp dialects (umbrella)"
status: Review
track: Language / MLIR
created: 2026-06-12
updated: 2026-06-14
issue: 23
epic: 17
---

# 0013 — MLIR topology compilation: the `vaked` + `hcp` dialects

Status: **Review** (2026-06-14) · Series: language design notes · Track:
**Language / MLIR** · Issue
[#23](https://github.com/peterlodri-sec/vaked-base/issues/23) · Epic
[#17](https://github.com/peterlodri-sec/vaked-base/issues/17)

> This note began as a single design sketch. It is now the **umbrella/index**
> for a six-part RFC-grade specification set ([0019](./0019-mlir-vaked-dialect.md)–[0024](./0024-mlir-lowering-staged-adoption.md)).
> The architectural verdict, the terminology, and the pipeline diagram live
> here; each dialect, pass, and the lowering contract are specified
> normatively in their own part.

> **Requirement keywords.** MUST / MUST NOT / SHOULD / SHOULD NOT / MAY across this set carry their
> [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119) + [RFC 8174](https://www.rfc-editor.org/rfc/rfc8174)
> (BCP 14) meanings **only when in ALL CAPS**; lowercase uses are ordinary prose.

## Abstract

The Vaked compiler models a multi-agent system's **state-dependency topology**
as two custom MLIR dialects and ahead-of-time-compiles the structural
guarantees the runtime depends on — DAG-ness, write-ahead registration
discipline, and the supervisor routing index — **before any agent runs**. The
high-level `vaked` dialect captures the agent dataflow graph (agents as ops,
state as SSA values); the low-level `hcp` dialect captures the protocol
mechanics RFC 0004 defines (write-ahead `DependencyRegistration`, rewind
scopes). Three passes lower `vaked` → `hcp` → LLVM, computing the critical
path, injecting the WAL sequence, and emitting the supervisor index along the
way.

Adoption is **staged**, and the staging is the load-bearing decision:

| Stage | What ships | Where |
|-------|-----------|-------|
| **Stage 0 — now** | the pass *semantics* as passes over the existing typed graph (LPG) inside `vakedc` — depth/cycle as a `check` diagnostic, registration injection + supervisor index as `0012` emitters | `vakedc/check.py`, `vakedc/lower.py` (shipped) |
| **Stage 1 — with compiled agents** | the real `vaked`/`hcp` MLIR dialects + progressive lowering, when agent binaries are AOT-compiled | this RFC set (0019–0024) |

The Stage-0 passes are the **reference semantics** the Stage-1 dialect verifier
must match — same typed graph in, same structural verdict out.

What **never** moves into MLIR: `eventd`, the `memory` store, the Zig
enforcement daemons, the OTP control plane. Those are dynamic I/O systems
(design: [eventd](../superpowers/specs/2026-06-12-eventd-design.md),
[`memory` 0014](./0014-memory-primitive.md)); MLIR compiles the *topology* they
run on, not the runtime itself.

## Terminology

The set's shared vocabulary. Each part repeats only the terms it uses; this
table is the canonical home, kept aligned with RFC 0004's terminology and
[`docs/protocol/README.md`](../protocol/README.md).

| Term | Definition |
|------|------------|
| LPG | The **typed semantic graph** (Lowered Property Graph) `vakedc` produces after parse → resolve → check — the Stage-0 substrate the pass semantics run on. |
| `vaked` dialect | The high-level MLIR dialect modelling the agent dataflow graph: agents as structural ops, state as SSA values ([0019](./0019-mlir-vaked-dialect.md)). |
| `hcp` dialect | The low-level MLIR dialect modelling the protocol mechanics RFC 0004 defines: write-ahead registration, canonical fetch, rewind scopes ([0020](./0020-mlir-hcp-dialect.md)). |
| Pass 1 / topology analysis | Critical-path + cycle analysis over the `vaked` dialect; rejects the build on a forbidden cycle or an exceeded depth bound ([0021](./0021-mlir-pass-topology-analysis.md)). |
| Pass 2 / WAL injection | Lowering that replaces every `vaked.consume` with the `hcp.*` write-ahead sequence ([0022](./0022-mlir-pass-wal-injection.md)). |
| Pass 3 / AOT supervisor index | Emission of the packed read-only routing table `agent-supervisord` loads at boot ([0023](./0023-mlir-pass-aot-supervisor-index.md)). |
| `state_dependency` edge | A topology edge where one agent consumes another's step output — the edge kind Pass 1 requires acyclic (RFC 0004 §5). |
| Topology epoch | A monotonically increasing version of the state-dependency graph, carried by every `hcp` artifact (RFC 0004 §7). |

## The set

| Part | Specifies | Status |
|------|-----------|--------|
| [0019 — `vaked` dialect](./0019-mlir-vaked-dialect.md) | ops, types, SSA semantics, verifier — TableGen-ready | Review |
| [0020 — `hcp` dialect](./0020-mlir-hcp-dialect.md) | ops, types, verifier; cross-linked to RFC 0004 §3.1 frames + `eventd` | Review |
| [0021 — Pass 1: topology analysis](./0021-mlir-pass-topology-analysis.md) | critical-path/cycle analysis, `maxDepth` bound, diagnostics | Review |
| [0022 — Pass 2: WAL injection](./0022-mlir-pass-wal-injection.md) | `vaked.consume` → `hcp.*` write-ahead lowering | Review |
| [0023 — Pass 3: AOT supervisor index](./0023-mlir-pass-aot-supervisor-index.md) | packed routing table, `agent-supervisord` boot load | Review |
| [0024 — lowering + staged adoption](./0024-mlir-lowering-staged-adoption.md) | `vaked→hcp→LLVM` contract; Stage 0 vs Stage 1; reference-semantics rule | Review |

## The unified pipeline

```text
 [ .vaked multi-agent source ]
             │  parse → resolve → check  (vakedc)
             ▼
        [ LPG ]  ── Stage 0: pass semantics run here today ──┐
             │  serialize the typed graph                    │
             ▼                                                │
   [ vaked dialect ] ──→ depth + cycle analysis      (Pass 1, 0021)
             │                                                │
             ▼                                                │
    [ hcp dialect ]  ──→ inject write-ahead frames    (Pass 2, 0022)
             │                                                │
             ▼                                                │
 [ lowering → LLVM / native ]                         (0024)  │
             │                                                │
             ▼                                                │
 [ compiled agent binaries + AOT supervisor index ]   (Pass 3, 0023)
             │                                                │
             ▼                                                ▼
 [ agent-supervisord + eventd + memory ]      ← the runtime; NOT in MLIR
```

In Stage 0 the three passes run as `vakedc` LPG passes (no MLIR dependency); in
Stage 1 the same semantics run as MLIR passes over the two dialects. The
dashed return path is the **reference-semantics contract** ([0024](./0024-mlir-lowering-staged-adoption.md) §4):
the Stage-1 verifier MUST agree with the Stage-0 passes on every graph.

## Anchoring (source conversation → repo reality)

| Source term | What it is here |
|-------------|-----------------|
| "RFC 0004 / RFC 0005" | [RFC 0004 — Multi-Agent State Dependency](../../protocol/rfcs/0004-multi-agent-state-dependency.md) (one RFC; "RFC 0005" is its recorded alias). |
| `DependencyRegistration` frame | The write-ahead "B depends on A's step-N output" registration — RFC 0004 §2–§3, logged via `eventd`, carrying the topology epoch. The `hcp` dialect ([0020](./0020-mlir-hcp-dialect.md)) lowers to it. |
| `rewind_scope` | A block vulnerable to upstream state drift — RFC 0004 §3.3/§6 (`RewindEvent` + cold-start verification). Modelled as `hcp.rewind_scope` ([0020](./0020-mlir-hcp-dialect.md) §4). |
| "MemPalace schemas" | The `memory` primitive ([0014](./0014-memory-primitive.md), #24) — explicitly **not** an MLIR target ([0024](./0024-mlir-lowering-staged-adoption.md) §3). |
| "multi-agent dependency graph" | The typed semantic graph `vakedc` already produces (the LPG). |

## Security considerations

The compiler is a **trust amplifier**: a structural guarantee proven at compile
time (acyclic state-dependency subgraph, registration-precedes-consumption) is
worth nothing if the lowering that emits the runtime artifacts can be bypassed.
Two set-wide invariants follow, detailed in the parts:

- The `hcp` write-ahead sequence ([0022](./0022-mlir-pass-wal-injection.md)) is
  **generated, never hand-authored** — a hand-written `DependencyRegistration`
  is a conformance smell (RFC 0004 §3.1).
- The AOT supervisor index ([0023](./0023-mlir-pass-aot-supervisor-index.md)) is
  a `0012`-style artifact: pure, total, hermetic, and **diffable**, so a
  tampered routing table is visible in review.

## Open questions

- **Diagnostic naming** is reconciled in [0021](./0021-mlir-pass-topology-analysis.md) §3:
  the shipped `E-WORKFLOW-CYCLE`/`E-WORKFLOW-DEPTH` (`vakedc/check.py`, 0015),
  the `E-TOPO-*` names this note originally proposed, and RFC 0004 §5.1's
  `E-CYCLE-DETECTED` are unified there.
- **When Stage 1 starts** is gated on agent binaries being AOT-compiled
  ([0024](./0024-mlir-lowering-staged-adoption.md) §2); until then the dialects
  are specified but unbuilt, and the Stage-0 passes are authoritative.
- Per-part open questions live under each part's "Open questions".

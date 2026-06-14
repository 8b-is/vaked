# Vaked Language Track

Vaked is a proposed typed, flake-native complement language for Nix.

It began as a way to make flake definitions, engines, and runtime declarations easier to author. It has now expanded into a capability graph language for agentic, native, mesh-aware, parallel systems.

## Current definition

Vaked is a **flake-native capability graph language** for declaring reproducible agentic, native, mesh-aware, parallel systems.

It compiles to:

- ordinary `flake.nix`
- NixOS modules
- Zig daemon configs
- eBPF policy manifests
- MCP broker configs
- OpenTelemetry config
- CrabCC indexes/catalogs
- generated documentation

## Core top-level declarations

```text
runtime
system
engine
host
network
filesystem
mcp
ebpf
budget
observability
runclass
workflow
index
catalog
stream
fiber
surface
mesh
device
mediaPipeline
parallel
service
secret
hostResource
ingress
container
memory
```

## Grammar

The normative EBNF grammar and its design notes are in
[`vaked/grammar/README.md`](../../vaked/grammar/README.md) (currently **v0.3**).

## Type system (Goal 2)

The Vaked type system — structural typing + per-kind schema contracts, a
**closed** constraint set, a typed capability taxonomy with an attenuation
partial order (POLA checked at type-time), bounded generics, and a total +
deterministic checking pipeline (parse → resolve → elaborate → check, *validate
before generating*) — is specified normatively in
[`0011-type-system.md`](./0011-type-system.md). Its built-in schema and
capability catalog is [`vaked/schema/parallel-types.md`](../../vaked/schema/parallel-types.md);
worked type-layer examples are in [`vaked/examples/types/`](../../vaked/examples/types/).

## Lowering (Goal 3)

Lowering — the stage **after** the Goal-2 check — turns the validated typed
semantic graph into the boring, inspectable artifacts Vaked owns (`gen/`) plus a
**Nix spine** (`flake.nix` + NixOS modules) that wires, builds, and deploys them.
It is a **pure, total, hermetic** function of (validated graph + pinned inputs):
same graph ⇒ byte-identical artifacts, with no network/IO during lowering
(fetching/building is the Nix build's job, pinned via `flake.lock` from
`trust = pinned{…}`). One emitter per target, selected by declared `emit`
targets; provenance is preserved per-artifact (generated header) and in
`.vaked/provenance.json`. Specified normatively in
[`0012-lowering.md`](./0012-lowering.md); hand-authored expected-output fixtures
for `operator-field.vaked` are in
[`vaked/examples/lowering/`](../../vaked/examples/lowering/).

## Memory (0014)

The `memory` primitive — `Memory<T>`, the MemPalace-shaped runtime-accumulated,
mined, replayable, capability-bound store (distinct from `index`/`catalog`/
`stream`) — is designed in [`0014-memory-primitive.md`](./0014-memory-primitive.md)
(#24), with its schema and the `memory` capability domain in
[`vaked/schema/parallel-types.md`](../../vaked/schema/parallel-types.md) and a
worked example in
[`vaked/examples/primitives/memory.vaked`](../../vaked/examples/primitives/memory.vaked).

## Workflow (0015)

The `workflow` kind — a typed **agent-step DAG** (the swe_af pattern): steps
conform to `workflowStep`, edges are checked acyclic (`E-WORKFLOW-CYCLE`), and
`maxDepth` bounds the critical path (`E-WORKFLOW-DEPTH`). Mesh edges delegate
authority; workflow edges order steps. Designed in
[`0015-workflow.md`](./0015-workflow.md) (#27); the daily-use calibration
example is
[`vaked/examples/agentfield-swe.vaked`](../../vaked/examples/agentfield-swe.vaked).

## Substrate candidates (0016)

The Wasmtime / Colmena / SPIFFE / NATS / TVM / ZKP technology batch is triaged
— design slots opened (#50/#51/#52), references recorded, and
already-have-its named — in
[`0016-substrate-candidates.md`](./0016-substrate-candidates.md).

## Topology compilation — the MLIR set (0013, 0019–0024)

The MLIR-based multi-agent topology compilation strategy — the `vaked` (agent
dataflow) and `hcp` (orchestration frames) dialects, the static depth/cycle
pass, automatic write-ahead dependency-registration insertion, and AOT
`agent-supervisord` index generation, staged over the existing typed graph — is
now an RFC-grade specification **set**. The umbrella/index +
terminology + staged-adoption verdict is
[`0013-mlir-topology-compilation.md`](./0013-mlir-topology-compilation.md) (#23);
the six parts:

- [`0019-mlir-vaked-dialect.md`](./0019-mlir-vaked-dialect.md) — the `vaked`
  dialect (agent dataflow ops, `!vaked.state_hash`, SSA semantics, verifier).
- [`0020-mlir-hcp-dialect.md`](./0020-mlir-hcp-dialect.md) — the `hcp` dialect
  (write-ahead registration, canonical fetch, rewind scope), cross-linked to
  RFC 0004 §3.1.
- [`0021-mlir-pass-topology-analysis.md`](./0021-mlir-pass-topology-analysis.md)
  — Pass 1 (critical-path/cycle, `maxDepth`; reconciles the diagnostic naming).
- [`0022-mlir-pass-wal-injection.md`](./0022-mlir-pass-wal-injection.md) —
  Pass 2 (`vaked.consume` → `hcp.*` write-ahead lowering).
- [`0023-mlir-pass-aot-supervisor-index.md`](./0023-mlir-pass-aot-supervisor-index.md)
  — Pass 3 (packed read-only routing table for `agent-supervisord`).
- [`0024-mlir-lowering-staged-adoption.md`](./0024-mlir-lowering-staged-adoption.md)
  — the `vaked→hcp→LLVM` contract, Stage 0 vs Stage 1, and the reference-semantics
  rule (the Stage-0 `vakedc` passes are authoritative until Stage 1 is proven
  equivalent).

## POLA formalization (0027)

The §4.5 POLA soundness argument is **informal** (hand-written, not
machine-checked). [`0027-pola-formalization.md`](./0027-pola-formalization.md)
is the **deferred** scaffold for mechanizing it in **Lean 4 + Mathlib** at the
spec level — the `≤` partial order, the `⊑` preorder, the path-attenuation and
cyclic-case lemmas, and the top `pola_invariant` theorem — with implementation
faithfulness and runtime enforcement explicitly out of scope. Blocked on the
`E-CAP-USE` use-check being implemented and negative-tested (Risk 6 /
`feat/cap-use-check`).

## Namespace & daemon-channel roster (0017)

Closing **branch-B** reference resolution — the checker half of
[#7](https://github.com/peterlodri-sec/vaked-base/issues/7): a built-in
`namespace` catalog (open value-namespaces like `pkgs`/`nix`, closed
daemon-channel and external-service heads) so the Goal-2 checker can reject a
dangling `engine = pkgs.doesNotExist` instead of waving it through. Designed in
[`0017-namespace-roster.md`](./0017-namespace-roster.md) (#8); the lowering half
(`_nix_attr_key`) already shipped.

## Golden commands

```bash
vaked fmt
vaked check
vaked emit graph
vaked emit nix
vaked emit docs
vaked explain runtime operator-field
vaked explain fiber mediaCompress
vaked explain index zigbeeFirmware
```

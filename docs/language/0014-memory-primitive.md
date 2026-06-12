# 0014 — `memory`: the MemPalace-shaped runtime memory primitive

Status: **design, grammar landed** (2026-06-12) · Series: language design notes ·
Issue [#24](https://github.com/peterlodri-sec/vaked-base/issues/24) · Epic
[#17](https://github.com/peterlodri-sec/vaked-base/issues/17)

## Spark

> mempalace is kind of the right "primitive" for memory (in this Vaked system
> point of view — new addition based on my heavy use)

The proving ground is **MemPalace**, the session-memory system used daily on
this very repo: agent transcripts are mined asynchronously in the background
into a durable, queryable store of distilled episodes, and recalled in later
sessions. Heavy use validated the *shape*; this note promotes that shape from
external tooling to a Vaked primitive, so every agent in the runtime
(epic #17) can declare its memory instead of improvising it.

## Why a new primitive (rule-2 justification)

A new top-level kind needs justification over composing existing primitives.
The three nearest kinds each model something else:

| Kind | What it is | Why it isn't memory |
|------|------------|---------------------|
| `index` | reproducible **build-time** corpus (pinned sources, `trust`) | read-only; nothing appends at runtime |
| `catalog` | queryable **materialization of an index** | a derived view, not a primary store |
| `stream` | **ephemeral** typed event flow (`retention`, `fps`) | events expire; no distilled, queryable residue |

`memory` is the missing fourth quadrant: **runtime-appended** (mined from
streams), **durable and replayable** (state = fold over the eventd log),
**queryable** (recall), and **capability-bound** (who may recall / append /
administer). Composition cannot express it: an `index` over a `stream` still
has no runtime append path, and a `catalog` still has no primary store to
materialize.

## Semantics

`Memory<T>` — a runtime-accumulated, mined, replayable store of typed entries.

- **Mining (the write path).** The `mine` normalizer distills raw events from
  the `source` stream(s) into entries of the `schema` type `T`. Mining is a
  *runtime* effect performed by the runtime plane — declaring a `memory`
  implies no evaluation-time side effect (determinism rule holds; evaluation
  still only produces the typed graph).
- **State = fold.** Memory entries are events on the per-runtime hash-chained
  `eventd` log ([design](../superpowers/specs/2026-06-12-eventd-design.md),
  #18); memory state is the fold over those events, resolving content against
  the arena (#16). Rewind/jump (Track D, #20) therefore rewinds memory **for
  free** — no separate snapshot discipline.
- **Recall (the read path).** Recall is mediated by the new `mem` capability
  domain (POLA, 0011 §4): `none < recall < append < admin`. A mesh node that
  holds `mem.recall` may read but not write; mining daemons hold
  `mem.append`; only the control plane holds `mem.admin`. (The domain is named
  `mem`, not `memory`: a top-level `capability memory` collides with
  `schema memory` in the LPG's kind-agnostic decl ids — #25.)
- **Scope.** `"session"` (one agent turn-sequence), `"agent"` (one agent across
  sessions — the MemPalace default), `"runtime"` (shared across the runtime's
  agents). Scope names the fold's partition key, not a storage location.

## Schema (normative copy in [`parallel-types.md`](../../vaked/schema/parallel-types.md))

```vaked
schema memory {
  field source    : Stream<T> | List<Stream<T>> { nonempty }   # what gets mined
  field schema    : Schema<T>    { optional }     # entry schema; binds T
  field mine      : Normalizer   { optional }     # distiller: raw events → entries
  field scope     : String       { optional oneof ["session", "agent", "runtime"] default = "agent" }
  field retention : Duration     { optional }     # entry time-to-live in the fold
  field emit      : List<ArtifactTarget> { optional nonempty }
}
```

```vaked
capability mem {
  grant none recall append admin
  order none < recall < append < admin
}
```

Worked example: [`vaked/examples/primitives/memory.vaked`](../../vaked/examples/primitives/memory.vaked).

## Lowering (output-first rule: what does it lower to?)

| Artifact | Target |
|----------|--------|
| **eventd store config** | the per-runtime log path + the memory's partition key (`scope`), so entries ride the existing hash-chained spine (#18) — `gen/memory/<name>.json` |
| **CrabCC recall index** | `emit` materializes the recall side as ordinary index/catalog artifacts (`catalog.jsonl`, `catalog.sqlite`) — CrabCC indexes |
| **docs** | the generated memory map per runtime |

The emitter is **landed** (`memory.store` in the 0012 §3.4 registry):
`vakedc lower` emits `gen/memory/<name>.json` per memory decl — source, mine,
scope, retention, recall `emit` targets, and the per-runtime eventd log path —
plus `gen/eventd.json` (the log contract) whenever a runtime declares any
memory/workflow.

## Runtime contract

Memory needs a runtime home with its own design → plan → implement cycle (like
eventd): a `memoryd` roster entry — the mining daemon that consumes `source`
streams, applies `mine`, appends to `eventd`, and serves recall queries against
the folded state, enforcing the `mem` capability domain. Noted in
[`docs/runtime/README.md`](../runtime/README.md).

## Relationship to MemPalace (the proving ground)

MemPalace remains the live instance of this shape (transcript mining via async
hooks; see CLAUDE.md patch-doctor). The primitive generalizes it: `source` =
the transcript stream, `mine` = the convos miner, `scope = "agent"`,
recall = the indexed palace. When the runtime exists, MemPalace becomes *a*
`memory` declaration rather than a special case — and the MLIR/AOT pipeline
([0013](./0013-mlir-topology-compilation.md), #23) can compile its schemas
ahead-of-time like any other.

## Open

- Recall query surface: is recall purely a runtime API, or does a `recall`
  expression form ever enter the language? (Lean: runtime API only — keep the
  language declarative.)
- Entry eviction: `retention` semantics inside a fold (tombstone events vs.
  fold-time filtering) — decide with the eventd compaction question.
- Cross-runtime memory (mesh-shared palaces) — interacts with the SHM arena
  graft design (#16).

# 0017 — `ralphloop`: the cached, closed-loop dogfooding primitive

Status: **design proposal (v0.x), not yet implemented in vakedc** · Series:
language design notes · Relates to: `tools/ralph/PURPOSE.md`,
`.github/workflows/ralph-tracks.yml`, `docs/superpowers/plans/2026-06-11-ralph.md`,
`docs/compiler/OPTIMIZATION_ROADMAP.md`

## Spark

> "express the ralph loop as a NATIVE Vaked primitive that does fully
> closed-loop dogfooding with a cache."

The **ralph loop** already exists as out-of-band tooling: a self-pacing,
controllable strategy agent that, each tick, surfaces the single most important
open decision across the Vaked ecosystem and appends it to an immutable,
hash-chained log (`tools/ralph/PURPOSE.md`). It is the project's standing
*dogfood* — it embodies Vaked's three theories (parallel, immutable, control)
before they land in the language.

This note promotes that shape from tooling to a Vaked **kind**: `ralphloop`. A
`ralphloop` declares a recurring agent loop whose iteration results are **cached
by input hash**, so re-running an unchanged input is a cache *hit* — byte-identical
to the miss it replaces.

## Why a new primitive (rule-2 justification)

A new top-level kind must justify itself over composing existing primitives. The
nearest kinds each model something else:

| Kind | What it is | Why it isn't a ralphloop |
|------|------------|--------------------------|
| `workflow` | a typed agent-step **DAG** (plan → code → review), each step run once (0015) | acyclic and one-shot; a ralphloop is a *recurrence* — the same step re-applied until a stop condition holds |
| `fiber` | one long-lived **daemon** consuming a stream | a fiber is the *executor*; a ralphloop is the *control structure* that drives a fiber repeatedly and memoizes its outputs |
| `parallel` | a supervised **fan-out** of fibers | spatial concurrency, not temporal iteration with carry-over state |
| `stream` | an **ephemeral** typed event flow | events expire; a ralphloop's iteration results are content-addressed and *cached* |

`ralphloop` is the missing **bounded-recurrence-with-memoization** quadrant:
*iterate one step* (a `fiber` ref), *carry input forward*, *stop on a declared
condition or iteration bound*, and — the load-bearing addition — *cache each
iteration keyed by a hash of its inputs*. Composition cannot express it: a
`workflow` self-edge is rejected as a cycle (`E-WORKFLOW-CYCLE`, 0015), and
neither `fiber` nor `parallel` has any notion of a per-iteration content-addressed
result cache.

### Why the cache is a first-class concern, not a runtime detail

The whole research bet behind ralph (`PURPOSE.md`) is *"compiling history into an
immutable, content-addressed event log lets an agent run indefinitely at near-flat
cost."* The cache **is** that bet, made declarable:

- If the cache were a runtime knob, two runs of the "same" loop could silently
  diverge in cost and content — the determinism oracle could not certify them.
- Making `cache { key, store, ttl }` part of the *declaration* means the cache
  key is part of the typed graph, hashable and reviewable, and the lowering can
  emit a cache contract the runtime must honor. The cache becomes a property the
  checker reasons about, not an optimization the runtime may or may not perform.

This mirrors Nix's own stance: content-addressing is a language-level guarantee,
not an opportunistic runtime cache. Vaked declares; the cache materializes.

## Semantics

`RalphLoop` — a bounded, deterministic recurrence over a single step fiber, with
per-iteration content-addressed memoization.

- **`input`** — the seed value for iteration 0 (a ref or literal/record). Each
  iteration's `output` becomes the next iteration's effective input (carry-over),
  unless the step is pure-in-`input` (see determinism, below).
- **`step`** — a ref to a `fiber` (the executor). Declaring the loop implies **no**
  evaluation-time side effect: like `memory` (0014), evaluation still only
  produces the typed graph. The fiber runs at *runtime*, under the supervision
  plane.
- **`cache { key, store, ttl }`** — a record (ordinary `assignment`s inside a
  `record`, per the grammar):
  - **`key`** — an expr that the runtime hashes to form the cache key. Canonical
    form: `hash([input, step.config])` (a list-app over the existing `hash`
    convention; see Determinism). If omitted, the key defaults to the hash of the
    *iteration input plus the resolved step config* — the safe default.
  - **`store`** — a path or backend ref (e.g. `./.ralph/cache` or `eventd.arena`)
    naming where iteration results are content-addressed.
  - **`ttl`** — a `duration` literal bounding cache entry lifetime.
- **`until`** — a stop-condition expr. **Closed:** it is a ref or a comparison
  *refinement-style* expression only — it does **not** introduce a general
  predicate sub-language (see EBNF delta and Open questions). Practically, `until`
  names a boolean-valued ref produced by the step (`until = step.output.converged`)
  or a built-in stop ref (`until = fixpoint`).
- **`max_iterations`** — a `number` hard bound (the loop always terminates;
  `until` may stop it sooner).
- **`output`** — a ref/path naming where the loop's *final* iteration result is
  published.

## Surface (no new block grammar — verified against the uniform-block decision)

The grammar's design decision #3 (v0.2) and the type-layer note both state the
rule explicitly: **"The grammar stays uniform: no per-kind block grammars."** A
`ralphloop` block is therefore an ordinary `block = "{" { stmt } "}"`, and every
field above is an ordinary statement form the grammar **already admits**:

| Field | Statement form (existing grammar production) |
|-------|----------------------------------------------|
| `input = ...` | `assignment` = `ident assign_op expr` |
| `step = someFiber` | `assignment` whose `expr` is a bare `app` (ref-only) |
| `cache { key = ..., store = ..., ttl = ... }` | `assignment` whose `expr` is a `record` (`"{" { assignment } "}"`) |
| `until = ...` | `assignment` |
| `max_iterations = 8` | `assignment` (number literal) |
| `output = artifacts.x` | `assignment` |

So `cache`, `until`, `step` are **not** keywords and need **no** grammar — they
are field names, exactly like `policy { ... }` on a fiber (`primitives/fiber.vaked`)
or `cache`-shaped records elsewhere. This matches how `memory` (0014) and
`workflow` (0015) landed: schema + checking + lowering, **no grammar change**
beyond, at most, the `kind` list.

### The one and only EBNF delta

The single change is to add `"ralphloop"` to the `kind` alternation in
`vaked/grammar/vaked-v0-plus.ebnf` (lines 127–134). Concretely, the `kind`
production's last line gains the new keyword:

```diff
  kind        = "runtime" | "engine"  | "host"
              | "network" | "filesystem" | "mcp"        | "ebpf"
              | "budget"  | "observability" | "runclass" | "workflow"
              | "index"   | "catalog" | "stream"         | "fiber"
              | "surface" | "mesh"    | "device"         | "mediaPipeline"
              | "parallel" | "schema" | "capability"
              | "service" | "secret" | "hostResource"   | "ingress"
-             | "container" | "memory" ;
+             | "container" | "memory" | "ralphloop" ;
```

That is the **entire** grammatical change. No new `stmt`, no new `expr` form, no
new record shape. (Do **not** apply this to the canonical grammar from this design
note — it lands when the kind is implemented, per the grammar-first convention.)

#### Is a genuinely new stmt form needed? No (with one watch-item)

The only field that *tempts* a new form is `until`, because a real stop condition
wants a predicate. We deliberately **decline** to add a predicate sub-language
here, for the same reason backpressure (design decision #4) and workflow
bounded-loops (0015) are deferred: *"It requires a conditional sub-language that
is not yet designed."* `until` is therefore restricted to:

1. a boolean-valued **ref** (`until = step.output.converged`, `until = fixpoint`), or
2. a comparison drawn from the **existing closed refinement vocabulary** reused as
   a value (`>=`, `<=`, `in n..m`) — *if and only if* the refinement-as-expr
   question (Open) is resolved.

Until that resolves, `until` is a ref only. This keeps `ralphloop` inside the
grammar's "no expression sub-language" guarantee.

## Type / check semantics (sketch — design only)

Following 0011's parse → resolve → elaborate → check pipeline and the pattern
established by `_check_workflow` (0015):

1. **Schema conformance.** A closed `ralphloop` record schema (normative copy to
   live in `vaked/schema/parallel-types.md`):

   ```vaked
   schema ralphloop {
     field input          : Ref | Record           { required }
     field step           : Fiber                   { required }
     field cache          : RalphCache              { required }
     field until          : Ref                     { optional }
     field max_iterations : Int                     { required >= 1 }
     field output         : Ref | Path              { optional }
   }
   schema RalphCache {
     field key   : Ref | Hash      { optional }   # defaults to hash([input, step.config])
     field store : Path | Ref      { required }
     field ttl   : Duration        { optional }
   }
   ```

   A loop missing `step`, `input`, `cache`, or `max_iterations` is
   `E-CONFORM-MISSING-FIELD`.

2. **`step` ref resolution** (mirrors 0015's `agent` rule): when `step`'s head
   names a sibling decl, that sibling **must** be a `fiber`; a sibling of any other
   kind is `E-REF-UNRESOLVED`. A `fiber.ghost` that names no sibling node is also
   `E-REF-UNRESOLVED`.

3. **Termination guarantee (`E-RALPH-UNBOUNDED`).** `max_iterations >= 1` is a
   schema refinement, so an unbounded loop is rejected at check time. `until`
   never *replaces* the bound; it only stops earlier. This is the loop analogue of
   `E-WORKFLOW-DEPTH`.

4. **Cache-key well-formedness (`E-RALPH-CACHE-KEY`).** If `key` is given, it must
   reduce (statically) to a hash over values reachable in the loop's declared
   inputs/config — no reference to runtime-only or non-deterministic refs (clock,
   rng). This is what lets the determinism oracle certify hit≡miss.

5. **Capability flow.** The `step` fiber's grants are checked by the existing POLA
   machinery (mesh/use checks, 0011 §4). A `ralphloop` carries no authority of its
   own (like a `workflow` step) — it only re-invokes the fiber.

## Determinism + caching semantics (ties to the determinism oracle)

The cache is only sound if a **hit is byte-identical to a miss**. The design makes
this a checkable property rather than a hope:

- **Cache key.** `key = hash([input_i, step.config])` for iteration `i` — a hash
  over (this iteration's input value, the resolved step configuration). Identical
  `(input, step.config)` ⇒ identical key ⇒ the stored result is reused verbatim.
- **Purity obligation.** The step fiber must be *deterministic in its declared
  inputs*: same input ⇒ same output, no hidden state, no wall-clock/rng reads. The
  checker's cache-key well-formedness rule (above) enforces the *declared* half;
  the runtime's determinism oracle certifies the *observed* half by re-running a
  sampled fraction of cache hits as misses and asserting byte-equality.
- **Content addressing.** `store` is content-addressed (CAS), the same spine
  `memory`/`eventd` already use (0014). A cache entry's address **is** its key, so
  a hit is a pure lookup and a miss writes the canonical bytes once. Replay/rewind
  (Track D, #20) therefore rewinds the cache for free, exactly as it does memory.
- **TTL.** `ttl` bounds entry lifetime; expiry forces a recompute (a miss that must
  reproduce the prior bytes if inputs are unchanged — the oracle's standing check).

## Closed-loop dogfooding (the research angle)

This is where `ralphloop` pays for itself: **Vaked uses `ralphloop` to drive its
own optimization and evaluation passes** — the system improving itself, declared in
itself.

Concretely, tie it to `docs/compiler/OPTIMIZATION_ROADMAP.md` and
`examples/evaluation/`:

- **The eval loop as a `ralphloop`.** The roadmap's benchmark suite
  (`examples/evaluation/bench.py`, the 1k/10k worker fixtures) is exactly a
  recurring "run → measure → record" tick. Declared as a `ralphloop`:
  - `input` = the current vakedc revision + the fixture set,
  - `step` = a fiber that runs `parse+check+lower` and emits timings,
  - `cache.key = hash([compilerRev, fixtureSet])` — **re-benchmarking an unchanged
    compiler on an unchanged fixture is a cache hit**, so the eval cost stays flat
    as history compounds (the `PURPOSE.md` "near-flat cost" bet, made literal),
  - `until = perf.regressed` (stop and surface when a phase regresses),
  - `output` = an append to the immutable results log the roadmap diffs
    (`baseline.json` → `v0.2-phase1.json`).
- **Self-optimization as recurrence.** The roadmap's Phase-4 "incremental checking"
  *itself* is a hash-keyed cache of per-fiber verdicts. A `ralphloop` whose
  `cache.key` is the fiber hash **is the language-level expression of that
  optimization** — the compiler's own incremental cache becomes a declarable Vaked
  construct, and the optimization the roadmap describes in Python becomes a thing
  the language can *say*. That is closed-loop dogfooding in the strict sense: the
  primitive that caches agent iterations is the same primitive that caches the
  compiler's checking of those iterations.
- **Self-demonstrating.** The ralph decision-loop (`tools/ralph/PURPOSE.md`)
  re-expressed as a `ralphloop` makes the dogfood a *Vaked declaration* rather than
  a workflow file: `step` = the decision-surfacing fiber, `cache.key =
  hash(projectState)`, `output` = the hash-chained decision log, `until` =
  never (run indefinitely, bounded per-tick by `max_iterations = 1`). The loop that
  reasons about Vaked's direction is then itself a Vaked program — the system
  demonstrates its own central primitive by running on it.

The research claims (`PURPOSE.md`: ratify-rate, cost/decision, coherence-over-time)
become *measurable properties of a declared `ralphloop`*: cost/decision is "cache
hit-rate × tick cost," and coherence is whatever fraction of ticks resolve to a
prior cached key.

Worked example: [`docs/language/examples/0017-ralphloop-cache.vaked`](examples/0017-ralphloop-cache.vaked).

## Lowering (output-first; emitter not yet built)

| Artifact | Target |
|----------|--------|
| **loop spec** | `gen/ralphloop/<name>.json` — `step` fiber ref, `max_iterations`, `until` ref, `output` target, and the resolved **cache contract** (key formula, store path/backend, ttl) — consumed by the supervision plane that drives the recurrence |
| **cache contract** | the CAS `store` path + canonical key formula, so the runtime and the determinism oracle agree on what a hit means |
| **eventd wiring** | `gen/eventd.json` — each iteration's start/finish/cache-hit rides the hash-chained log; a loop run is a fold, so replay/rewind (#20) applies for free |

## Runtime contract

`ralphloop` needs a runtime home with its own design → plan → implement cycle: a
`ralphloopd`-shaped roster entry (or an extension of the supervision plane) that
drives the recurrence, consults the CAS `store` before invoking `step`, writes
canonical result bytes on a miss, evaluates `until`/`max_iterations`, and emits the
per-iteration events. Note this in `docs/runtime/README.md` when the kind is
accepted.

## Open questions

- **`until` expressivity.** Ref-only is safe but thin. Adopting the closed
  refinement vocabulary (`>=`, `in n..m`) as a *value-level* comparison would let
  `until = metric >= threshold` without opening a general predicate language —
  but that reuse is exactly the deferred conditional sub-language (decision #4,
  0015 bounded loops). Decide together with those.
- **Carry-over vs. pure-input.** Does iteration `i+1` consume iteration `i`'s
  `output` (stateful fold) or always the original `input` (pure map until
  `until`)? The cache key differs (`hash([input_i, …])` vs `hash([input_0, i, …])`).
  Lean: stateful fold, with the iteration index folded into the key.
- **Cache scope.** Is the cache per-loop, per-runtime, or content-global (shared
  across loops with identical keys)? Interacts with the SHM arena graft (#16) the
  same way cross-runtime memory does (0014 Open).
- **Default `store`.** Should `store` default to the runtime's `eventd.arena` so
  the field can be omitted, matching `memory`'s eventd-by-default spine?
- **Numbering.** Resolve the `0013` slug collision before merge (see top note).

## Status

**Design proposal (v0.x), not yet implemented in vakedc.** No parser, schema,
checker, or emitter exists for `ralphloop` yet. The example
[`0017-ralphloop-cache.vaked`](examples/0017-ralphloop-cache.vaked) will **not**
parse under the current vakedc (the `kind` is not in the grammar) and is marked as
a design proposal in its header.

# 0012: Lowering — Validated Graph to Artifacts (Goal 3)

## Status

Normative. This note defines **lowering** — the stage that turns a *validated
typed semantic graph* (the output of the Goal-2 checker,
[`0011-type-system.md`](./0011-type-system.md) §6) into the **boring,
inspectable artifacts** Vaked owns, plus the **Nix spine** that wires, builds,
and deploys them. It is the specification for the **Goal 3** lowering pass.

It is the direct successor to Goal 2: where 0011 stops at *"validated graph,
ready to lower,"* this note starts there and stops at *"artifacts on disk, with
provenance."* It realizes manifesto principles
([`0001-language-manifesto.md`](./0001-language-manifesto.md)) directly: *Compile
to boring artifacts*, *Validate before generating*, *Preserve provenance*,
*Explain everything*, *Support raw Nix escape hatches*, and *Keep evaluation
deterministic and side-effect-free*.

It is paired with three documents:

- **Type system** — [`0011-type-system.md`](./0011-type-system.md) defines the
  graph that lowering *consumes*. Lowering never re-checks and never runs on an
  invalid graph (§1).
- **Primitives** — [`0008-parallel-fibers-indexes-surfaces.md`](./0008-parallel-fibers-indexes-surfaces.md)
  introduces the declarations (`index`, `catalog`, `stream`, `fiber`, `surface`,
  `mesh`, `device`, `mediaPipeline`, `parallel`) and lists the *Compiler
  artifacts* this note maps each to.
- **Built-in catalog** — [`vaked/schema/parallel-types.md`](../../vaked/schema/parallel-types.md)
  is the schema/capability data; lowering reads schema-typed fields (e.g.
  `index.emit`, `fiber.policy`, `index.trust = pinned{…}`) but adds no new
  vocabulary. The surface syntax is [`vaked/grammar/README.md`](../../vaked/grammar/README.md)
  (v0.3); **lowering requires no grammar changes** — every selector it uses
  (`emit` targets, `nix("…")`) is already writable.

Worked, hand-authored **expected-output fixtures** for `operator-field.vaked`
live in [`vaked/examples/lowering/`](../../vaked/examples/lowering/) (no compiler
exists yet; the fixtures are the spec-by-example).

### Scope (what this is NOT)

To keep the mantra intact (*Vaked declares. Nix materializes. Zig enforces. eBPF
testifies.*), lowering is deliberately bounded:

- **No fetching, no build, no deploy.** Lowering emits *text*. Fetching sources,
  building Zig daemons, and activating NixOS configurations are the **Nix
  build's** job (§4), pinned by `flake.lock` derived from `trust = pinned{…}`.
  Lowering performs **no network and no IO beyond writing the declared output
  tree** (§2).
- **No re-checking.** Lowering assumes a valid graph (0011 §6). It does not
  re-run conformance, constraints, generics, or capability flow. A graph that
  failed checking is never lowered.
- **No new computation.** Lowering is pure graph→text rendering. It has no
  interpreter, no eval, no arithmetic on user values beyond structural
  projection of already-typed nodes (§2.4). The closedness boundary of 0011 §6.2
  extends here: if a target *seems* to need eval-time logic, that is a language
  question, not an emitter feature (§9).
- **No concrete mappings for the deferred targets.** eBPF policy manifests, OTel
  config, systemd units, and surface launcher configs get an **emitter interface
  slot** and a *contract* for what their mapping must eventually cover (§7);
  the mappings themselves are deferred.
- **No runtime semantics.** What the artifacts *do* once running (supervision,
  enforcement, audit) is the daemons' job ([`docs/runtime/README.md`](../runtime/README.md)),
  out of scope here.

---

## 1. Pipeline placement

Lowering is the stage **after** 0011's check. The full Vaked pipeline is:

```text
source text
    │  parse → resolve → elaborate → check        (0011 §6 — Goal 2)
    ▼
validated typed semantic graph   ── or ──▶  diagnostic set  (stop; nothing lowered)
    │  lower                                       (this note — Goal 3)
    ▼
artifact tree  (gen/ direct artifacts + Nix spine)  +  .vaked/provenance.json
```

Lowering runs **only** on a graph that produced *no* diagnostics (0011 §6.1:
*"A valid file's typed semantic graph is the hand-off to Goal 3 lowering …
nothing is lowered from an invalid graph."*). This is the manifesto principle
*Validate before generating* made structural: validation strictly precedes
generation, and the two stages share no error path — by the time lowering runs,
every node is typed, every ref is resolved, every default is inserted, every
union arm is selected, and every capability edge has been shown to attenuate.

Concretely, lowering consumes exactly the artifact 0011 §6.1 stage 3
(*elaborate*) builds and stage 4 (*check*) blesses:

- **nodes** — one per declaration, typed by its kind-schema, with defaults
  inserted (0011 §1.2), union arms selected (0011 §2.2), and generic parameters
  bound (0011 §5);
- **edges** — refs (data flow, e.g. `fiber.input = stream.screenrec`) and
  delegations (authority flow, e.g. a `mesh` edge);
- **source spans** — every node and edge carries the byte/line span of the AST
  node it came from (0011 §6.5); lowering propagates these into provenance (§6)
  without consulting source text again.

Lowering reads this graph and the **pinned inputs** recorded on it (`index.trust
= pinned{…}`, the resolved `engine` derivations). It writes the artifact tree.
That is the whole contract.

---

## 2. Lowering is pure, total, and hermetic

0011 §6 argues its checker is total + deterministic. Lowering inherits and
extends that discipline. The property we want is:

> **Lowering is a pure, total, hermetic function of (validated graph, pinned
> inputs).** The same graph and the same pinned inputs produce **byte-identical**
> artifacts, on any machine, with no observation of the outside world.

This section argues each adjective, in the style of 0011 §6.3–§6.4.

### 2.1 Determinism (same graph ⇒ byte-identical artifacts)

Lowering is a function `lower : (Graph, Pins) → (Files, Provenance)`. It is
deterministic because every input it reads is fixed by the graph, and every
choice it makes is a function of that input:

- **Ordering is canonical, not incidental.** Wherever lowering emits a sequence
  (modules in `flake.nix`, rows in a catalog, sections in `RUNTIME.md`, entries
  in `provenance.json`), it orders by a **stable key derived from the graph** —
  declaration source order for top-level decls (0011 preserves source order;
  cf. the `litanyfmt` rule that *encoding never depends on source order* but
  *emission follows source order* for readability), lexicographic order for
  set-like collections (e.g. capability grants, system doubles). Lowering never
  orders by hash-map iteration, wall-clock, or filesystem `readdir` order.
- **No ambient inputs.** Lowering reads no clock, no `$RANDOM`, no environment,
  no locale, no hostname, no UUID source. Timestamps, if a target format wants
  one, are **not** emitted (a generated header names the *source decl*, not the
  time — §6.1); a build that needs a timestamp gets it from Nix at build time,
  not from lowering.
- **Hashes are over content, not over runs.** The `inputs-hash` recorded in
  provenance (§6.2) is a hash of the *pinned inputs and the projected node*, not
  of the run — so it too is reproducible.

This is the artifact-level analogue of 0011 §6.3: there, *"two checks of the same
file yield the same graph or the same diagnostics."* Here, *two lowerings of the
same graph yield the same bytes.*

### 2.2 Totality (lowering of a valid graph always terminates and succeeds)

Lowering of a **validated** graph is total: it terminates, and it does not fail.

- **Termination.** Lowering is a single bounded traversal. It visits each node
  once per emitter that selects it, and the emitter set is finite (§3, the
  registry). Each emitter folds a node (and its already-resolved neighbours)
  into text in finite steps — there is no fixpoint, no recursion on unbounded
  data, no user predicate to evaluate (contrast 0011 §6.2). The graph is a
  finite DAG of typed nodes; the traversal is finite.
- **No failure path on a valid graph.** Every condition that *could* make an
  emitter "not know what to do" — an unknown field, a missing required field, a
  dangling ref, a capability over-grant, a generic mismatch — is exactly a
  condition 0011 §6 already rejected. Because lowering runs only post-validation
  (§1), those conditions cannot occur. Lowering therefore has no diagnostics of
  its own for *graph* problems.

  The one residual error class is **environmental** and lives *outside* the pure
  function: the host filesystem rejects the write (permissions, disk full). That
  is an IO error of the writer, not a lowering diagnostic; the pure
  `(Graph,Pins) → Files` computation still succeeded. (Compilers that want a
  "what would I emit?" dry run can compute `Files` without writing them.)

  The only *deferred* targets (§7) are not failures: a `runtime` that declares,
  say, an OTel mapping simply has its OTel emitter slot produce **nothing yet**
  (an explicit, documented no-op), not an error.

### 2.3 Hermeticity (no network, no IO during lowering)

Lowering is **hermetic**: as a computation it performs no network access and no
filesystem reads of remote or unpinned content. The only IO is writing the
declared output tree (`gen/`, the spine files, `.vaked/`).

- **Fetching is the build's job, not lowering's.** When `index zigbeeFirmware`
  declares `trust = pinned { commit, sha256 }`, lowering does **not** fetch the
  repo. It *transcribes* the pin into a `flake.nix` input (§4.2); the actual
  fetch happens during `nix build`, gated by `flake.lock`. Likewise an
  `engine`'s `package = zig.build{…}` lowers to a derivation *reference*; the
  Zig compile runs in the Nix sandbox, not in lowering.
- **Sources are values, not effects.** `github("owner/repo")` and
  `raw.github("owner/repo","file")` are *already* typed `Source` values in the
  graph (0011 §2.3, the auxiliary catalog). Lowering reads the value; it never
  dereferences it.

This is the structural reason the mantra holds: **Vaked declares** (lowering
renders the declaration) and **Nix materializes** (the build fetches and
compiles). Pushing all fetching/building behind `flake.lock` is what lets
"same graph ⇒ byte-identical artifacts" coexist with real-world inputs that
*do* change: the inputs are pinned, so the graph fixes them.

### 2.4 What "no smuggled computation" means precisely

Lowering may **project** a typed node into text: read its fields, follow its
resolved refs, render scalars in the target format's lexical syntax, and
template fixed structure around them. Lowering may **not**:

- evaluate user expressions, arithmetic, or predicates (there are none to
  evaluate; 0011's constraint set is closed and already checked);
- derive a value that is not a structural function of the graph (e.g. it may not
  "compute a free port", "resolve DNS", "pick a default commit");
- read any input not on the graph or in `Pins`.

If a prospective target appears to require any of the above, that is the §9
stop-and-report boundary, mirroring 0011 §6.2: the answer is a *language* change
(a new typed, closed field that carries the needed value explicitly), never an
escape hatch inside an emitter.

---

## 3. Emitters and the registry

### 3.1 Emitter interface

An **emitter** is a pure function:

```text
emit : (Graph, Nodes) → (Files, ProvenanceEntries)

  Graph   : the whole validated typed semantic graph (read-only)
  Nodes   : the subset of nodes this emitter is responsible for
  Files   : a set of { path, bytes } rooted at the output tree
  ProvenanceEntries : one entry per emitted artifact (or region), §6
```

`Graph` is passed whole (read-only) so an emitter can follow a node's resolved
refs — e.g. the `fiber` emitter reads `mediaCompress` *and* follows
`input = stream.screenrec` to that stream node — without re-resolving anything;
the edges are already in the graph. `Nodes` is the emitter's *assignment*, fixed
by selection (§3.3).

One emitter owns one **target**. Targets are the entries of the 0008 *Compiler
artifacts* list, partitioned in §3.4/§7 into *implemented*, *the spine*, and
*deferred*.

### 3.2 Constraints — what an emitter may NOT do

These are the rules that make §2 hold per-emitter. They are normative.

1. **No IO** other than returning `Files`. An emitter does not read files, open
   sockets, spawn processes, or read environment/clock/random. (It returns bytes;
   the driver writes them.)
2. **No nondeterminism.** Given the same `(Graph, Nodes)` an emitter returns
   byte-identical `Files`. All ordering is by a stable graph-derived key (§2.1).
   No hash-map iteration order, no time, no UUIDs.
3. **No graph mutation.** `Graph` and `Nodes` are read-only. An emitter may not
   add/remove/retype nodes or edges, insert defaults, or re-resolve refs — all
   of that already happened in elaboration (0011 §6.1 stage 3). Emitters cannot
   communicate through the graph.
4. **No cross-emitter state / no ordering dependence.** Emitters do not share
   mutable state and may run in any order (or in parallel). The output is the
   *union* of their `Files`; paths must not collide across emitters (the
   partition of targets guarantees this — each owns a distinct path namespace,
   §3.4).
5. **No re-checking and no new diagnostics for graph problems.** A valid graph
   cannot present an emitter with an illegal input (§2.2). An emitter therefore
   has no error path for graph content; a deferred emitter produces an explicit
   no-op, not an error.
6. **No new vocabulary.** An emitter reads only schema-defined fields and
   built-in auxiliary values (0011 §2.3). It introduces no field or selector that
   the grammar/schema doesn't already define.

A useful test (the "registry test"): **adding an emitter touches no core.** A
new target is a new function plus one registry row; nothing else in lowering, in
0011, or in the grammar changes. If adding a target *would* require a core
change, the target is asking for something the language doesn't express — see §9.

### 3.3 `emit`-driven selection

Which emitters run is a function of the graph, in two layers:

- **The Nix-spine emitter ALWAYS runs.** Every runtime lowers to a flake +
  NixOS module(s) (§4); there is no `emit` toggle for the spine. (This is what
  makes the output deployable rather than a loose pile of files.)
- **Direct emitters are selected by declared `emit` targets.** A declaration
  that carries an `emit` field (the schema permits it on `index` and `catalog`)
  names its desired artifacts as built-in `ArtifactTarget` values; each names
  exactly one direct emitter:

  | `emit` target (built-in value) | direct emitter (target) |
  |--------------------------------|--------------------------|
  | `catalog.jsonl`                | catalog → JSONL          |
  | `catalog.sqlite`               | catalog → SQLite         |
  | `nix.derivation`               | CrabCC index derivation (folded into the spine, §5) |
  | `sqlite("./path.db")`          | catalog → SQLite at the given path |

  So `index zigCorpus { … emit = [catalog.jsonl, catalog.sqlite,
  nix.derivation] }` selects the JSONL emitter, the SQLite emitter, and the
  CrabCC-derivation emitter **for that node**. An `index` with no `emit` (e.g.
  `zigbeeFirmware`) selects no direct catalog emitter — it still contributes its
  pinned `trust` input to the spine (§4.2) and can be the `from` of a separate
  `catalog` decl (which carries its own `emit`).

- **`RUNTIME.md` is emitted once per `runtime`.** The generated-docs emitter
  (§5.1) is not `emit`-gated either: documenting the runtime is unconditional
  ("explain everything"). It is selected by the presence of the `runtime` node,
  not by an `emit` value.

Selection is therefore *entirely* a read of the graph: spine + docs are
structural; direct artifacts follow `emit`. No grammar change is needed because
`emit = [ … ]` is already the writable selector (0011 §2.3 lists `catalog.jsonl`,
`catalog.sqlite`, `nix.derivation` as built-in `ArtifactTarget` values).

### 3.4 The registry

The registry is a static table `target → emitter`, partitioned three ways:

```text
ALWAYS (structural — run on presence of the node):
  nix.spine        runtime, + all build/wire inputs   → flake.nix, NixOS module(s)   §4
  docs.runtime     runtime                              → gen/RUNTIME.md               §5.1

emit-SELECTED (direct artifacts in gen/, run when an emit target names them):
  catalog.jsonl    index/catalog (emit ∋ catalog.jsonl)   → gen/catalog/<name>.jsonl  §5.3
  catalog.sqlite   index/catalog (emit ∋ catalog.sqlite)  → gen/catalog/<name>.sql    §5.3
  crabcc.index     index        (emit ∋ nix.derivation)   → crabcc index drv (in spine) §5.3
  zig.daemoncfg    fiber/engine                            → gen/zig/<name>.json        §5.2

runtime plane (#18/#24/#27 — presence-gated, like zig.daemoncfg):
  workflow.spec    workflow (presence)                     → gen/workflow/<name>.json  (0015: steps/edges/depth, AOT supervisor spec)
  memory.store     memory (presence)                       → gen/memory/<name>.json    (0014: source/mine/scope/retention/emit + log)
  eventd.config    runtime w/ any memory|workflow          → gen/eventd.json           (#18: per-runtime log path + boot contract)

DEFERRED (interface slot defined; mapping deferred — §7):
  ebpf.policy      mesh/capability grants    → (no-op today)
  otel.config      stream/observe            → (no-op today)
  systemd.units    fiber/parallel/surface    → (no-op today)
  surface.launcher surface                   → (no-op today)
```

Adding a row is adding an emitter. Removing the deferral on a deferred row is
replacing its no-op body with a real mapping — still no core change.

> Note on `zig.daemoncfg` selection: a fiber's Zig daemon config (§5.2) is part
> of *materializing the fiber on the runtime* and is emitted as part of wiring
> the runtime (it is referenced by the NixOS module as an installed file). It is
> grouped with the direct `gen/` artifacts because it lands in `gen/zig/` and is
> independently inspectable; it is not `emit`-gated (a fiber has no `emit`
> field), it is selected by the presence of the fiber node under a runtime.

---

## 4. The Nix spine

The Nix spine is the always-emitted backbone: a `flake.nix` plus one or more
NixOS modules that **wire, build, and deploy** the artifacts Vaked owns. It is
the structural realization of *Nix materializes*.

### 4.1 `flake.nix` outputs

The emitted `flake.nix` has these outputs, each a function of the runtime node:

```text
inputs              pinned, never moving: nixpkgs at the toolchain baseline rev +
                    one input per source (explicit rev when the decl pins it) / engine src (§4.1, §4.2)
nixosModules.<runtime>   the wiring module(s) for this runtime (§4.3)
packages.<system>.*      built Zig daemons & engines (e.g. zigDaemon, zigimg) +
                         CrabCC index derivations (from emit = nix.derivation, §5.3)
devShells.<system>.default   a shell with the toolchains the runtime needs
apps.<system>.*          surface launchers (deferred body, §7) + nix("…") apps (§8)
```

`<system>` ranges over the runtime's `systems` field (e.g. `"x86_64-linux"`,
`"aarch64-linux"` for `operator-field`) — `flake.nix` iterates them with the
conventional `forAllSystems`/`eachSystem` idiom. The mapping from declaration to
output:

| Vaked node | flake output |
|------------|--------------|
| `runtime <name>` | `nixosModules.<name>`, and the `forAllSystems` scaffold |
| `engine <e>` / fiber `engine = <e>` | `packages.<system>.<e>` (the built derivation) |
| `index` with `emit ∋ nix.derivation` | `packages.<system>.<index>-crabcc-index` (§5.3) |
| `surface <s>` | `apps.<system>.<s>` (launcher; deferred body §7) |
| `app nix("…")` | `apps.<system>.<name>` verbatim (§8) |
| `parallel`/`fiber`/`stream` | wired in the NixOS module (§4.3), not a flake output by themselves |

**Inputs are pinned, never moving (normative).** The emitted `inputs` set never
references a moving channel ref (e.g. `nixos-unstable`). Specifically:

- An input emitted for a **source decl that pins itself** (`trust = pinned{…}`)
  uses the author-asserted explicit `rev` from `trust.pinned.commit` (§4.2).
- **`nixpkgs`** is emitted pinned to the **toolchain's pinned baseline rev** — an
  explicit 40-hex rev fixed by the Vaked toolchain release, not a channel name —
  so two lowerings of the same graph under the same toolchain emit byte-identical
  `inputs` (§2.1). (Lowering does not *resolve* the rev; the toolchain hands it
  the baseline rev as a pin, exactly as it hands over `Pins` for engines, §1.)
- An **unpinned source decl** (no `trust`, e.g. the `github(…)` list in
  `zigCorpus`) is still emitted as an input, but with no author-asserted digest;
  its concrete rev is recorded by the lock step (§4.2).

The committed **`flake.lock`** — produced at first `nix build`, not by lowering —
records the *full* resolution: the pinned revs above plus the resolved revs for
unpinned inputs. Lowering emits the pinned `inputs`; the build writes the lock.
(No `flake.lock` fixture is committed here because lowering does not emit it —
§2.3, §4.2; the README notes this.)

### 4.2 `trust = pinned{…}` → flake inputs + `flake.lock`

This is the load-bearing mapping for hermeticity (§2.3). A pinned source becomes
a flake input whose revision is fixed, and the fix is recorded in `flake.lock`.

For `index zigbeeFirmware { source = raw.github("Koenkk/zigbee-OTA",
"index.json"); trust = pinned { commit = "<commit>"; sha256 = "<sha256>" } }`,
lowering emits:

```nix
# in flake.nix inputs:
inputs.zigbeeFirmware-src = {
  url   = "github:Koenkk/zigbee-OTA/<commit>";   # commit from trust.pinned.commit
  flake = false;                                  # raw source, not a flake
};
```

and the corresponding `flake.lock` node pins `rev = "<commit>"` and
`narHash`/`sha256 = "<sha256>"` (from `trust.pinned.sha256`). The rules:

- **`trust.pinned.commit` → the input's pinned `rev`** (in the URL and in
  `flake.lock`).
- **`trust.pinned.sha256` → the input's content hash** in `flake.lock`
  (`narHash`/`sha256`), so `nix build` verifies the fetch against the declared
  digest. A mismatch is a *build-time* failure, exactly where fetching happens —
  never a lowering failure (§2.2).
- **An unpinned `index` source** (e.g. the `github(…)` list in `zigCorpus`,
  which carries `normalize`/`emit` but no `trust`) still becomes a flake input,
  but its lock entry is the conventional flake-managed pin (Nix records the rev
  it resolved at lock time). `trust = pinned{…}` is the *author-asserted* pin;
  its presence makes the digest part of the declaration rather than of the lock
  step.

Either way the **graph fixes the inputs** and the **build fetches them** —
lowering only transcribes. This is precisely why §2.1's "same graph ⇒
byte-identical artifacts" survives contact with mutable upstreams.

### 4.3 NixOS module(s) — wiring the daemons

`nixosModules.<runtime>` is the wiring layer. It does **not** re-declare policy;
it *installs* the direct-emitted `gen/` artifacts and points the runtime's
daemons at them. The runtime materializes onto the daemon roster
([`docs/runtime/README.md`](../runtime/README.md)): an OTP control plane
(`agent-supervisord`) supervising single-purpose Zig daemons, with the membranes
of [`PROJECT_CONTEXT.md`](../context/PROJECT_CONTEXT.md) enforced by the named
daemons.

For `operator-field`, the implied wiring (from its decls) is:

| Vaked node | Wired onto (roster) | Module does |
|------------|---------------------|-------------|
| `parallel "operator-runtime"` (`supervisor = otp`) | `agent-supervisord` (OTP) | declares the supervision group over the fibers, `strategy = "supervised-dag"` |
| `fiber mediaCompress` (`output = artifacts.compressedMedia`) | `fs-snapshotd` (filesystem membrane — artifact capture) | installs `gen/zig/mediaCompress.json` (§5.2) and sets the daemon's config path to it |
| `stream ebpfEvents` (`source = agentGuardd.ringbuf`) | `agent-guardd` (ebpf membrane) | references the ringbuf channel as the stream source |
| `stream screenrec` (`source = agentpipe.screenrec`) | media capture (agentpipe) → `fs-snapshotd` | wires the screen-capture channel into `mediaCompress` |
| `surface operatorMap` (`mode = raylib`) | operator surface | references `apps.<system>.operatorMap` (launcher deferred, §7) |

The module references each `gen/` artifact as an **installed file** (e.g.
`environment.etc."vaked/zig/mediaCompress.json".source = ./gen/zig/mediaCompress.json;`
or the equivalent per-daemon option), so the inspectable artifact on disk is the
*same bytes* the daemon consumes — no second source of truth.

> The eBPF policy manifest, OTel collector config, systemd unit details, and the
> surface launcher body that this module would ultimately reference are
> **deferred** (§7). The module slot that references them exists; the artifacts
> themselves are no-ops today.

---

## 5. Direct artifacts (`gen/`) and the three exemplar mappings

Direct artifacts are the files Vaked emits and owns, landing in **`gen/`**
(committed and inspectable). Each carries the generated header (§6.1). Three
exemplars are specified field-by-field below; the deferred targets (§7) are
interface-only.

### 5.1 Exemplar 1 — Generated docs: `gen/RUNTIME.md`

`RUNTIME.md` is a human-readable rendering of the `runtime` node — the
"explain everything" artifact. It is a pure projection of the graph into prose +
tables; it introduces no information not in the graph.

Sections, in this fixed order (each a projection of the named node-kind):

1. **Header & summary** — runtime name, `systems`.
2. **Indexes** — one row per `index`: name, `source`(s), `normalize`/`chunk` if
   present, `trust` (pinned commit, abbreviated) if present, `emit` targets.
3. **Streams** — one row per `stream`: name, `source` channel, `type`,
   `retention`/`fps` if present.
4. **Fibers** — one row per `fiber`: name, `engine`, `input` ref, `output` ref,
   policy summary.
5. **Surfaces** — one row per `surface`: name, `mode`, `fps`, `input` refs,
   `views`.
6. **Parallel groups** — one row per `parallel`: name, member fibers,
   `strategy`, `supervisor`.
7. **Capability grants** — per principal (mesh node / fiber), the grant-set
   (0011 §4.3); for `operator-field` this is sparse (no `mesh` decl), so the
   section renders the daemon-channel uses the streams imply (e.g. consuming
   `agentGuardd.ringbuf` *uses* an `ebpf` grant) and is otherwise "none
   declared." Decl-level provenance points each row back to its source span.

Ordering within each section is source order of the decls. No timestamps; the
header (§6.1) names the source, not the time.

### 5.2 Exemplar 2 — Zig daemon config: `gen/zig/<fiber>.json`

A `fiber` (with its `engine`) lowers to a **JSON** config file consumed by the
Zig daemon that runs the fiber. JSON is chosen because the Zig daemons parse a
small, well-specified config format and JSON serializes deterministically once a
canonical key order is fixed (see §2.1); the generated header is a leading
`"_generated"` string field (JSON has no comments — §6.1 adapts the header per
format).

For `operator-field`, `fiber mediaCompress` (`output =
artifacts.compressedMedia`) is the artifact-producing fiber; its config is
consumed by **`fs-snapshotd`** (the filesystem-membrane daemon responsible for
artifact capture, per the roster). Field-by-field mapping from the `fiber`
schema (and the linked `stream`/`engine` nodes):

| Vaked source (graph) | Config field | Value for `mediaCompress` |
|----------------------|--------------|----------------------------|
| `fiber.engine` (ref → engine node) | `engine` | `"zigimg"` |
| resolved engine package (Pins) | `engine_package` | the `packages.<system>.zigimg` store-path *reference* (resolved by Nix at build; lowering writes the attr name, not a path — §2.3) |
| `fiber.input` (ref → `stream.screenrec`) | `input.stream` / `input.source` | `"screenrec"` / `"agentpipe.screenrec"` |
| `stream.screenrec.type` | `input.type` | `"Media.Frame"` |
| `stream.screenrec.fps` | `input.fps` | `10` |
| `fiber.output` | `output.target` | `"artifacts.compressedMedia"` |
| `fiber.policy.strip_metadata` | `policy.strip_metadata` | `true` |
| `fiber.policy.max_pixels` | `policy.max_pixels` | `"4K"` |
| `fiber.policy.formats` | `policy.formats` | `["png","webp"]` |
| `fiber.budget` (optional, absent) | `budget` | omitted |
| `fiber.observe` (default `false`) | `observe` | `false` |

Every field is a direct projection of an already-typed node field or a resolved
ref. There is no computed value: `engine_package` is an *attribute name* the
NixOS module/flake resolves, not a path lowering computes (§2.3, §2.4).

**Key order is fixed schema order, not sorted (normative).** Keys are emitted in
the order of the field table above — that table's row order **is** the canonical
key order — *not* lexicographically sorted. `"_generated"` (§6.1) is always the
first member. An **absent optional field is omitted entirely**, not emitted as
`null` (e.g. `mediaCompress` declares no `budget`, so the config has no `budget`
key — see [`gen/zig/mediaCompress.json`](../../vaked/examples/lowering/gen/zig/mediaCompress.json)).
Nested objects (`input`, `output`, `policy`) follow the sub-field order shown in
their table rows. The same mapping shape applies to any fiber; `mediaCompress` is
the worked instance.

### 5.3 Exemplar 3 — CrabCC index + catalog

An `index` (optionally with a `catalog` built `from` it) lowers to a **CrabCC
index derivation** plus the **SQLite/JSONL catalog artifacts** its `emit`
selects. This is the *CrabCC indexes* leg of the mantra.

Selection (per §3.3): the emitter set for `index zigCorpus { emit =
[catalog.jsonl, catalog.sqlite, nix.derivation] }` is {JSONL, SQLite,
CrabCC-derivation}.

**a. CrabCC index derivation** (`emit ∋ nix.derivation`). Folded into the spine
as `packages.<system>.zigCorpus-crabcc-index`. The derivation runs CrabCC at
*build* time over the pinned sources; lowering only emits the derivation
expression. The `index` fields map to CrabCC options:

| Vaked `index` field | CrabCC option |
|---------------------|---------------|
| `source` (list of `github(…)` / `raw.github(…)`) | the input corpus (one fetched input per source, §4.2) |
| `normalize = crabcc.markdown` | CrabCC normalizer = `markdown` |
| `chunk = crabcc.semantic { max_tokens, overlap }` | CrabCC chunker = `semantic`, with `max_tokens`/`overlap` passed through (the `crabcc.semantic` record *is* the option struct, 0011 §2.3) |
| `schema = schema.<S>` (if present) | the item schema the rows are validated against |
| `trust = pinned{…}` (if present) | the input pin (§4.2) |

(`zigCorpus` has `normalize = crabcc.markdown` and no `chunk`; the `chunk` row
applies to indexes that carry it, e.g. the `zigRefs` form in 0008.)

**b. JSONL catalog** (`emit ∋ catalog.jsonl`) → `gen/catalog/zigCorpus.jsonl`.
One JSON object per indexed item, newline-delimited. The generated header is the
**first line**, a JSON object with a `_generated` key (§6.1), so the file stays
valid JSONL. Row shape follows the index's item schema (`T`, bound per 0011
§5.1); for an unschematized corpus it is CrabCC's default record shape.

**c. SQLite catalog** (`emit ∋ catalog.sqlite`, or a `catalog` decl with
`emit = sqlite("…")`) → `gen/catalog/<name>.sql` (a deterministic SQL schema +
`INSERT` script; the `.db` binary is built from it by the spine, keeping the
committed artifact a text diff). For a `catalog` decl, the `key` field maps to
the table's primary key / index:

| Vaked `catalog` field | SQLite artifact |
|-----------------------|------------------|
| `from = index.<I>` (binds `T`) | the table's column set = `T`'s fields |
| `key = ["a","b",…]` | `PRIMARY KEY (a, b, …)` / unique index |
| `emit = sqlite("./var/firmware.db")` | output path of the built `.db` |

The catalog's `T` must equal the source index's `T` (0011 §5.1) — already
checked, so the column set is unambiguous at lowering.

---

## 6. Provenance

Provenance is *Preserve provenance* + *Explain everything* made concrete, at
**decl-level granularity**. It has two parts: a per-artifact header and a
machine-readable map.

### 6.1 Per-artifact generated header

Every direct artifact carries, as its first line(s), a header naming the source.
The canonical text is:

```text
generated by Vaked from <file>:<decl> — do not edit
```

rendered in the **comment syntax of the target format** (the header is the same
information in every format; only the comment delimiter changes):

| Format | Header rendering |
|--------|------------------|
| Markdown (`RUNTIME.md`) | `<!-- generated by Vaked from operator-field.vaked:runtime operator-field — do not edit -->` |
| Nix (`flake.nix`) | `# generated by Vaked from operator-field.vaked:runtime operator-field — do not edit` |
| JSON (Zig config) | first member `"_generated": "generated by Vaked from operator-field.vaked:fiber mediaCompress — do not edit"` (JSON has no comments) |
| JSONL (catalog) | first line `{"_generated":"generated by Vaked from operator-field.vaked:index zigCorpus — do not edit"}` |
| SQL (catalog) | `-- generated by Vaked from operator-field.vaked:catalog firmware — do not edit` |

`<file>` is the source path; `<decl>` is the declaration kind + name that the
artifact is *primarily* derived from (the artifact's "owning" decl). The header
carries **no timestamp** (determinism, §2.1) — it names the source decl so a
reader (or a `vaked explain`) can jump straight back to it.

### 6.2 `.vaked/provenance.json` — schema

`.vaked/provenance.json` is the complete, machine-readable provenance map for a
lowering run. It maps **artifact path → list of entries**, one entry per
artifact or per *region* of an artifact (decl-level granularity: each region
attributes to exactly one source decl).

> **Erratum (vakedc lower, 2026-06-10).** The manifest lands at
> `<out>/provenance.json` — the root of the lowering output tree (alongside
> `flake.nix` and `gen/`), where `<out>` is the `--out` directory (default
> `.vaked/lower/`); lowering a repo in-place uses `<out> = .vaked/`, which is the
> `.vaked/provenance.json` this section names.

Schema (normative; this is itself emitted deterministically — §2.1):

```text
ProvenanceFile {
  version    : Int                 # schema version of this file (currently 1)
  source     : Path                # the .vaked source file lowered
  artifacts  : Map<Path, [Entry]>  # artifact path (relative to output root) → entries
}

Entry {
  region?     : String             # OPTIONAL: name/anchor of the region within the
                                    #   artifact (e.g. a flake output attr, a RUNTIME.md
                                    #   section, a catalog table). Absent ⇒ the entry
                                    #   covers the whole artifact.
  sourceFile  : Path               # the .vaked file the region came from
  decl        : String             # the source declaration: "<kind> <name>"
                                    #   (e.g. "fiber mediaCompress", "index zigCorpus")
  span        : Span               # the source span of that decl (from 0011 §6.5)
  emitter     : String             # the registry target that produced it
                                    #   (e.g. "zig.daemoncfg", "nix.spine", "docs.runtime",
                                    #    "catalog.jsonl", "catalog.sqlite", "crabcc.index")
  inputsHash  : String             # hash over (pinned inputs + projected node) for this
                                    #   region — reproducible (§2.1); ties the artifact to
                                    #   the exact inputs that produced it
}

Span {                             # identical shape to 0011 §6.5's diagnostic span
  file       : Path
  byteStart  : Int                 # byte offset of the decl's LEADING KEYWORD
  byteEnd    : Int                 # EXCLUSIVE: one byte past the decl's closing "}"
  line       : Int                 # 1-based line of byteStart
  col        : Int                 # 1-based column of byteStart
}
```

**`artifacts` map key order (canonical).** The top-level `artifacts` map is
emitted with its keys in **lexicographic order by artifact path**, comparing
paths by Unicode code point (byte order for the ASCII paths used here — so an
uppercase letter sorts before a lowercase one, e.g. `gen/RUNTIME.md` precedes
`gen/catalog/…`). This is the §2.1 "lexicographic order for set-like
collections" rule applied to the artifact map, and it makes the file's top-level
ordering a pure function of the artifact set, independent of emitter run order
(§3.2.4). (The per-artifact `[Entry]` lists are ordered by contributing-decl
source order, as elsewhere in §2.1.)

**`Span` convention (canonical).** A decl's `Span` is fixed as: `byteStart` =
the byte offset of the decl's **leading keyword** (the `runtime`/`index`/
`stream`/`fiber`/`surface`/`parallel` token, *not* the name or the `{`);
`byteEnd` = **exclusive**, i.e. one byte past the decl's closing `}`;
`line`/`col` are **1-based** and locate `byteStart`. (`[byteStart, byteEnd)` is a
half-open range, so `byteEnd − byteStart` is the decl's byte length.) This
matches 0011 §6.5 and is exactly what the fixture's spans encode.

Properties:

- **Decl-level.** Every `Entry.decl` names one declaration; every `Entry.span`
  is that decl's span. A single artifact built from several decls (e.g.
  `flake.nix`, `RUNTIME.md`) has *multiple* entries — one per contributing decl,
  distinguished by `region`. An artifact built from one decl (e.g.
  `gen/zig/mediaCompress.json`) has a single whole-artifact entry (no `region`).
- **Round-trippable to source.** `(sourceFile, span)` lets `vaked explain` (0011
  §6.5) jump from any artifact region to the exact source token — the same
  source-map mechanism, reused for output.
- **Reproducible.** `inputsHash` is content-addressed over the graph projection
  + pins, so re-lowering an unchanged graph yields the same hashes (§2.1).
- **`inputsHash` keys the resolved inputs of the *projection*, not the decl.**
  Two regions that attribute to the same `decl` can carry different
  `inputsHash`es when they project different resolved inputs: e.g. an
  engine-package region hashes the resolved engine's pinned inputs (the
  `packages.zigimg` flake output, even though its owning `decl` is the
  `fiber mediaCompress` that references the engine — see the fixture, where that
  region's hash is labelled `engine-zigimg`), while the fiber-config region for
  the same fiber hashes the fiber node's own projection. The hash keys *what the
  region was projected from*; `decl` keys *which source token it attributes to*.
- **Escape-hatch entries included.** A `nix("…")` app gets an entry too (§8),
  with `emitter = "nix.passthrough"`, so even verbatim Nix is attributed.

A worked excerpt consistent with this schema is in
[`vaked/examples/lowering/provenance.json`](../../vaked/examples/lowering/provenance.json).

---

## 7. Interface-stubbed (deferred) targets

These targets have a **registry slot and a contract**, but their mapping is
**deferred**. Each slot's emitter exists as an explicit no-op (§2.2, §3.2.5) —
emitting it produces nothing today, not an error. Defining the slot now keeps
the registry test honest (adding the real mapping later touches no core) and
records *what the mapping must cover* so it isn't reinvented.

| Target (registry) | Selected by | Mapping must eventually cover | Deferred because |
|-------------------|-------------|-------------------------------|------------------|
| `ebpf.policy` | `mesh` nodes + capability grants (0011 §4); network/ebpf membrane | per-principal allow/deny sets for network egress, file, and process events — compiled from the capability grant-sets — consumable by `agent-guardd` | the eBPF policy *format* and the grant→rule compilation are a daemon-design concern ([`docs/runtime/README.md`](../runtime/README.md)); no concrete format is approved yet |
| `otel.config` | `stream` with `observe`/telemetry intent; the OTel collector | mapping each observed stream/fiber to an OTel pipeline (receiver → processor → exporter) for `otelcol` | the OTel mapping needs the telemetry schema, not yet specified |
| `systemd.units` | `fiber`/`parallel`/`surface` needing host units | service units for the Zig daemons / surface processes, with the dependency order implied by `parallel.strategy` and `supervisor` | unit details depend on the daemon packaging, deferred with the daemons |
| `surface.launcher` | `surface` node | the launcher config/app that starts a `mode = raylib` surface with its `input`/`views` wired | the surface backend (raylib host integration) is not yet specified |

The `surface.launcher` slot is the one deferred target that still surfaces in the
spine today, because §4.1 makes `apps.<system>.<s>` a structural output of the
flake (the attribute is named for the surface decl). To keep the slot a genuine
no-op without leaving a dangling attribute, lowering emits a **deferred stub
app** derived from *nothing but the surface decl name*: an `apps.<system>.<s>`
whose `program` is a `writeShellScript` that exits non-zero after printing the
message `vaked: surface launcher lowering deferred (0012 §7)` to stderr. It wires no `input`,
no `views`, and **no engine/fiber package** (routing the launcher through an
unrelated fiber's engine would contradict §4.1 and this section). When the real
raylib mapping lands it replaces the stub body — still no core change (the §3.2
registry test). The fixture
([`vaked/examples/lowering/flake.nix`](../../vaked/examples/lowering/flake.nix),
`apps.operatorMap`) shows exactly this stub.

**Contract common to all four** (so the eventual emitters still satisfy §2/§3):
each must be a pure projection of already-typed graph nodes (no new computation,
§2.4); each lands either in `gen/` (a direct artifact, with a §6.1 header) or is
referenced by the NixOS module (§4.3); each contributes decl-level provenance
entries (§6.2). When a mapping lands, it replaces the no-op body and adds nothing
to the core — exactly the §3.2 registry test.

---

## 8. Escape hatch: `nix("…")` pass-through

The manifesto's *Support raw Nix escape hatches* is realized without any special
grammar (the grammar README is explicit: `nix("…")` is a *conventional `app`*
whose ref is the plain identifier `nix` and whose string argument is an opaque
Nix expression fragment — there is no special production for it).

Lowering treats a `nix("…")` app as **verbatim pass-through into the Nix spine**:

- The string argument is emitted **unchanged** (byte-for-byte) into the spine —
  typically as (or within) an `apps.<system>.<name>` output (§4.1), or wherever
  the app appears structurally. Lowering does **not** parse, validate, reformat,
  or evaluate the fragment — it is opaque (consistent with §2.4: lowering renders
  it, it does not compute it).
- The pass-through still gets a **provenance entry** (§6.2): an `Entry` with
  `decl` = the enclosing app/decl, `span` = the `nix("…")` app's source span, and
  `emitter = "nix.passthrough"`. So even hand-written Nix is attributed back to
  the exact source token, and a reviewer can see *which* output is an escape
  hatch versus Vaked-generated.

This keeps the escape hatch honest: it is *visible* (a distinct emitter in
provenance), *bounded* (it lands in the spine, surrounded by generated outputs
that still carry their own headers), and *non-magical* (opaque text in, opaque
text out — no smuggled computation).

---

## 9. The "no smuggled computation" stop rule

This note's analogue of 0011 §6.2. If, while specifying or implementing an
emitter, a target appears to require something beyond **pure graph→text
rendering** — evaluating a user predicate, computing a value not present in the
graph, reading an ambient input, fetching/derefencing a source, or mutating the
graph — that is **not** an emitter feature to add. **Stop and report it** as a
concern.

The correct resolution is one of:

1. **The value belongs in the graph.** Add a typed, closed field (a 0011 §3
   constraint-respecting field, or a new built-in `ArtifactTarget`/auxiliary
   value) that carries it *explicitly*, so the author declares it and the checker
   validates it. Lowering then merely projects it. (This is the 0011 §6.2 move —
   "propose a language change" — applied to Goal 3.)
2. **The work belongs to the build.** If it is genuinely effectful (fetching,
   compiling, resolving store paths), it belongs behind `flake.lock` in the Nix
   build (§2.3, §4.2), not in lowering.

Neither resolution adds an escape hatch *inside* an emitter. This boundary is
what keeps §2 (pure, total, hermetic) true as targets are added.

---

## 10. Cross-references

- [`0011-type-system.md`](./0011-type-system.md) — the checker; §6 produces the
  validated graph lowering consumes, and §6.2/§6.5 are mirrored here (§2, §6,
  §9).
- [`0008-parallel-fibers-indexes-surfaces.md`](./0008-parallel-fibers-indexes-surfaces.md)
  — the primitives and the *Compiler artifacts* list this note maps each to.
- [`0001-language-manifesto.md`](./0001-language-manifesto.md) — *Compile to
  boring artifacts*, *Preserve provenance*, *Validate before generating*,
  *Support raw Nix escape hatches*, *Explain everything*, *Keep evaluation
  deterministic and side-effect-free*.
- [`vaked/grammar/README.md`](../../vaked/grammar/README.md) — surface syntax;
  the `app`/`nix("…")` form (§8) and the `emit` selector (§3.3) are already
  writable — **no grammar change** for lowering.
- [`vaked/schema/parallel-types.md`](../../vaked/schema/parallel-types.md) — the
  schema fields lowering projects (`index.emit`, `fiber.policy`, `trust =
  pinned{…}`, etc.).
- [`docs/context/PROJECT_CONTEXT.md`](../context/PROJECT_CONTEXT.md) — the core
  stack (Vaked source → graph → artifacts → host) and the mantra this note
  realizes.
- [`docs/runtime/README.md`](../runtime/README.md) — the daemon roster the Nix
  spine wires onto (§4.3) and the deferred targets defer to (§7).
- [`vaked/examples/lowering/`](../../vaked/examples/lowering/) — hand-authored
  expected-output fixtures for `operator-field.vaked`.

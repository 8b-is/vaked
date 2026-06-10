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
input
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

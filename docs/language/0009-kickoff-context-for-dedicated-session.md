# 0009: Kickoff Context for Dedicated Language Session

## Goal

Start a dedicated session focused only on the Vaked language.

The runtime architecture, Zig daemon stack, eBPF enforcement, and agent system are context. The main work is now language shape, semantics, syntax, and compiler milestones.

## Current Vaked definition

Vaked is a typed, flake-native capability graph language for declaring reproducible agentic, native, mesh-aware, parallel systems.

It compiles to ordinary artifacts:

- `flake.nix`
- NixOS modules
- Zig daemon configs
- eBPF manifests
- MCP broker policy
- OTel config
- CrabCC indexes/catalogs
- generated docs
- surface launcher configs

## Must preserve

- Nix remains the substrate.
- Generated artifacts are inspectable.
- Evaluation is deterministic and side-effect-free.
- Capabilities are explicit.
- Raw Nix escape hatches exist.
- `vaked explain` is a first-class UX.
- The language does not become a general app language.

## New language primitives to evaluate

```text
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

## Dedicated session agenda

1. Restate the language identity in one paragraph.
2. Define the semantic graph types.
3. Decide which top-level declarations are v0, v0.1, later.
4. Refine the syntax family.
5. Define imports, merges, defaults, overrides, and raw Nix.
6. Draft the v0 grammar.
7. Draft the v0 typechecker model.
8. Draft the first compiler targets.
9. Define example files.
10. Define repo milestones and acceptance criteria.

# 0003: Reference Map

## Borrow from

- Nix: flakes, derivations, store integration.
- Nickel: records, contracts, mergeable config.
- CUE: constraints and validation.
- Dhall: total programmable config.
- Starlark: deterministic embedded language.
- Jsonnet/KCL/HCL: config-generation ergonomics.
- OPA/Rego: policy decisions as data.
- OTP: supervision vocabulary.
- Zig: explicit native systems posture.
- MLIR: dialects, SSA use-def graphs, progressive lowering, pass infrastructure.
- MemPalace: mined, replayable session memory (the `memory` primitive's shape).
- Wasmtime/Component Model: snapshotable, instruction-metered worker sandboxes
  (designed: `docs/superpowers/specs/2026-06-13-wasm-worker-isolation-design.md`).
- Colmena: purely functional fleet deployment (`host.deploy` consumer).
- SPIFFE/SPIRE + NATS: transport identity and subject-mapped event fan-out
  (designed: RFC 0006).
- Temporal: durable-execution framing (we realize it as the eventd fold + the
  supervisord workflow_engine).
- crane/dream2nix, CA-Nix: granular + content-addressed build caching.
- TVM, polyhedral: below/inside-MLIR compilation for inference and scheduling.
- Linear/affine types, CCN/NDN, ZKP (RISC Zero): future type/transport/proof
  borrowings, triaged in 0016.
- Zigbee: mesh/device/capability topology.
- CrabCC: raw indexes and reproducible catalogs.

## Where it lands

- **Type system (Goal 2)** — the structural+schema discipline, the *closed*
  constraint set (CUE/Nickel-flavoured but total, no predicate language), the
  capability attenuation order, generics, and the total/deterministic checking
  pipeline are specified in [`0011-type-system.md`](./0011-type-system.md), with
  the built-in catalog in [`../../vaked/schema/parallel-types.md`](../../vaked/schema/parallel-types.md)
  and the surface syntax in [`../../vaked/grammar/vaked-v0-plus.ebnf`](../../vaked/grammar/vaked-v0-plus.ebnf) (v0.3).
- **Topology compilation** — the MLIR borrowings (dialects, SSA dependency
  graphs, passes, AOT lowering) land in
  [`0013-mlir-topology-compilation.md`](./0013-mlir-topology-compilation.md).
- **Memory** — the MemPalace borrowing lands as the `memory` primitive in
  [`0014-memory-primitive.md`](./0014-memory-primitive.md).
- **Substrate & distribution** — the Wasmtime/Colmena/SPIFFE/NATS/… batch is
  triaged (slot / reference / have-it) in
  [`0016-substrate-candidates.md`](./0016-substrate-candidates.md).

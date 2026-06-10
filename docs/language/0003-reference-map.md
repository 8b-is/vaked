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
- Zigbee: mesh/device/capability topology.
- CrabCC: raw indexes and reproducible catalogs.

## Where it lands

- **Type system (Goal 2)** — the structural+schema discipline, the *closed*
  constraint set (CUE/Nickel-flavoured but total, no predicate language), the
  capability attenuation order, generics, and the total/deterministic checking
  pipeline are specified in [`0011-type-system.md`](./0011-type-system.md), with
  the built-in catalog in [`../../vaked/schema/parallel-types.md`](../../vaked/schema/parallel-types.md)
  and the surface syntax in [`../../vaked/grammar/vaked-v0-plus.ebnf`](../../vaked/grammar/vaked-v0-plus.ebnf) (v0.3).

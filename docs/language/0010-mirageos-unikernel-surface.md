# 0010 — MirageOS as a unikernel materialization surface

Status: **exploration** · Series: language design notes

## Spark

> `mirage/mirage` + nix + vaked ?!?!

- [mirage/mirage](https://github.com/mirage/mirage) — a library OS for constructing **unikernels**: minimal, single-purpose, capability-secure VMs/binaries (OCaml).
- [mirage/mirage-www](https://github.com/mirage/mirage-www) — the MirageOS site, itself shipped as a unikernel.

## The idea

Today the canonical Vaked compilation path is:

```text
Vaked source → NixOS host → OTP supervision plane → Zig enforcement daemons → eBPF evidence → surfaces
```

MirageOS offers a **second materialization target** for an enforcement membrane: instead of (or alongside) a Zig daemon supervised on a shared NixOS host, a membrane can become a **sealed unikernel** — deny-by-default *by construction*, with an attack surface of essentially "the code you linked." This is the strongest possible reading of the `process`/`network` membranes: a workload that physically cannot do what it wasn't linked to do.

```text
Vaked membrane decl
    ↓ (Nix materializes)
MirageOS unikernel  (OCaml, only the libraries the membrane needs)
    ↓
deployed on a hypervisor / mesh node as a sealed surface
```

Nix is the bridge: MirageOS builds are reproducible and Nix can drive `mirage configure` / `mirage build`, so a Vaked declaration could emit a unikernel target the same way it emits a NixOS module.

## Where it fits the membranes

- `network` — unikernel has *only* the network stack you linked; deny-by-default is the default.
- `process` — no general-purpose OS underneath; "supervised execution" becomes "this is the only thing that runs."
- `mesh`/`device` — small, sealed unikernels are attractive leaf nodes on the device/mesh graph.
- `surface` — `mirage-www` shows a unikernel *is* a serveable surface.

## Open questions

1. **Language seam.** Vaked's enforcement story is Zig + eBPF on Linux. MirageOS is OCaml unikernels. Is Mirage an *alternative* backend, a *complement* for specific leaf membranes, or a research spike?
2. **eBPF testimony.** A unikernel has no host kernel to attach eBPF to. What replaces "eBPF testifies" for a Mirage-materialized membrane — in-unikernel attestation? host-hypervisor evidence?
3. **Toolchain weight.** OCaml/opam/`mirage` in the dev shell is heavy; gate behind a dedicated `devShells.mirage` rather than the default shell.
4. **Capability mapping.** How does a Vaked capability graph lower onto Mirage's functor/device-driver model?

## Next step

Spike: take one minimal membrane (e.g. a DNS oracle for the `network` membrane) and materialize it both ways — Zig daemon vs MirageOS unikernel — and compare attack surface, reproducibility, and the eBPF-testimony gap.

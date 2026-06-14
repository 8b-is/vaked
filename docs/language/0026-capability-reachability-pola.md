---
doc: 0026
title: "Capability reachability — POLA & confused-deputy lints"
status: Draft
track: Language
created: 2026-06-14
---

# 0026 — Capability reachability: POLA & confused-deputy lints

Status: **Draft** · Series: language design notes · Track: Language

## Abstract

In the object-capability model, security is *reachability in the
reference/authority graph*: "only connectivity begets connectivity," and
deny-by-default egress maps almost 1:1 onto "no ambient authority." Because Vaked
declares the capability graph as a first-class artifact (the LPG built in
`vakedc/resolve.py`), the checker can perform authority analysis at *compile time*
that runtime systems can only discover late. This note specifies the
capability-reachability pass added to `vakedc check` (issue #226): per-node
authority derived from the mesh, two advisory least-authority lints
(`W-POLA-EXCESS`, `W-CONFUSED-DEPUTY`), and the documented limit on what a network
membrane can and cannot attenuate.

## Motivation

`vakedc` already enforces **per-edge attenuation** on mesh delegation edges
(`E-CAP-ATTENUATION`, 0011 §4.4): for `a -> b`, every grant the receiver `b` holds
must be `<=` some grant the sender `a` holds in the same domain. That is a *local*
property of a single edge. Two *graph-level* least-authority hazards are invisible
to a per-edge rule:

1. **Over-grant (POLA violation).** A node may hold a strong capability it never
   needs. Attenuation says nothing about whether a node's *own* grant is justified
   — only about what flows across an edge.
2. **Confused deputy.** A shared, high-authority deputy reachable from multiple
   callers acts under *its own* identity on behalf of weaker callers. Each
   delegation edge into the deputy can be individually attenuation-clean while the
   aggregate shape still launders authority.

Vaked sees the whole graph at compile time, so it can flag both.

## The capability graph as the authority graph

The relevant edges of the LPG (see `vakedc/resolve.py`):

| Edge label | Meaning |
|------------|---------|
| `requires_capability` | a node/decl holds a `domain.grant` |
| `routes_to` | a mesh `a -> b` delegation edge |

A mesh `node`'s `capabilities = [domain.grant, …]` list is its **held authority**.
Its egress allow-set / effective authority is the union of (a) its own grants and
(b) the grants reachable by following `routes_to` edges, attenuated per edge. The
out-edges of a node are exactly what the eBPF deny-by-default manifest should
encode (`emit_ebpf_policy` in `vakedc/lower.py` already compiles a `network`
membrane's allow-set from `egress(host, port)` rules; wiring transitive
reachability into that emitter is tracked as a follow-up — see *Status* below).

### Declared need (`needs`)

The built-in `meshNode` schema is **open**, so a node may declare an optional

```vaked
needs = [fs.repo_rw]
```

list alongside `capabilities`. `needs` is the node's least-authority *budget*: the
maximum authority the node claims it requires, expressed in the same
`domain.grant` ref form as `capabilities`. It is validated against the capability
registry exactly like `capabilities` (unknown domain/grant ⇒ the usual
`E-CAP-UNKNOWN-DOMAIN` / `E-CAP-UNKNOWN-GRANT` errors). A node that omits `needs`
opts out of the POLA-excess lint (no declared budget ⇒ nothing to compare).

## The lints

Both lints are **advisory warnings** (`severity = "warning"`). They never block a
`check`; they surface a hazard with the node name and the offending grants so an
author can tighten the graph or consciously accept the shape.

### `W-POLA-EXCESS`

For a node that declares `needs`, for each held grant `dom.g`: if `dom.g` is *not*
`<=` some declared need in the same domain (i.e. the node is granted strictly more
than it claims to need), emit `W-POLA-EXCESS` against the node's `capabilities`,
naming the node, the held grant, and the declared need.

### `W-CONFUSED-DEPUTY`

A node is a **shared deputy** when it (a) holds at least one capability of its own
and (b) is the `routes_to` target of **two or more distinct callers**. Such a node
multiplexes multiple callers while acting under its own identity — the classic
confused-deputy shape. Emit `W-CONFUSED-DEPUTY` against the deputy node, naming the
deputy, the distinct callers, and the held capabilities, and recommend keeping
delegation inside Vaked-minted capabilities.

This deliberately fires even when every incoming edge is attenuation-clean: the
hazard is the *aggregation* of callers onto one authority-bearing sink, which a
per-edge rule cannot see.

## §2 — The channel-vs-reference attenuation gap

A network / eBPF membrane gates **channels**: it decides whether a connection from
principal P to host:port H is allowed. It **cannot** wrap or attenuate a capability
passed *inside* an allowed connection. Once `worker` is allowed to talk to
`egressProxy`, the membrane has no say over what `egressProxy` does with its own
`net.egress` grant on `worker`'s behalf — that is app-layer delegation, and it can
escape the declared graph.

Consequences and the recommended discipline:

- **Keep delegation inside Vaked-minted capabilities.** If authority is only ever
  passed as a Vaked `domain.grant` (which the checker attenuates per edge), the
  graph stays sound. Authority smuggled inside an opaque application payload over
  an allowed channel does not.
- **Re-derive edges at the daemon.** Where an application protocol *does* carry
  delegation, parse a capability-aware protocol at the Zig enforcement daemon so it
  can re-derive the reference edges and re-check attenuation at runtime, rather than
  trusting the channel grant alone.
- `W-CONFUSED-DEPUTY` is the compile-time *warning* for exactly this gap: it points
  at the shared deputy where app-layer delegation is most likely to launder
  authority the membrane cannot attenuate.

## Determinism

The pass is a pure read of the graph. Nodes are visited in sorted name order and
callers are sorted before rendering, so diagnostics are byte-stable across runs
(verified by the existing determinism group of `test_vakedc_check.py`).

## Examples

- `vaked/examples/types/pola-violation.vaked` — emits one `W-POLA-EXCESS`
  (`builder` holds `fs.host_rw`, needs only `fs.repo_rw`) and one
  `W-CONFUSED-DEPUTY` (`proxy` is the delegation target of `worker` and `cron`).
- `vaked/examples/types/pola-least-authority.vaked` — the clean pair: every node
  holds exactly its declared need and no shared deputy arises, so the pass is
  silent.

## Status

- ✅ Per-node held authority + declared `needs` from the mesh.
- ✅ `W-POLA-EXCESS` and `W-CONFUSED-DEPUTY` warnings with node names + offending
  grants/edges.
- ✅ Design note (this document) on the channel-vs-reference attenuation gap.
- ✅ Example pair exercising a warning case and a clean least-authority graph.
- ⏳ Follow-up: expose the transitive reachability set to `emit_ebpf_policy` so the
  per-node egress allow-set in `gen/ebpf.policy.json` is literally the out-edges of
  each node (the eBPF deny-by-default manifest). Tracked on #226.

## References

- Miller, "Capability Myths Demolished"; <https://en.wikipedia.org/wiki/Object-capability_model>
- <https://tvcutsem.github.io/membranes>; <https://en.wikipedia.org/wiki/Confused_deputy_problem>
- 0011 §4.4 (capability attenuation), `vakedc/check.py` `_check_mesh`
- `docs/research/` prior-art on durable-runtime capability graphs

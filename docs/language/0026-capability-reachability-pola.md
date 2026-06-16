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
(`W-POLA-EXCESS`, `W-CONFUSED-DEPUTY`), the **POLA use-check** error
(`E-CAP-USE`, 0011 §4.3 — a node may not exercise authority it does not hold),
and the documented limit on what a network membrane can and cannot attenuate.

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
opts out of *both* POLA checks — the `W-POLA-EXCESS` lint and the `E-CAP-USE`
use-check (no declared budget / use set ⇒ nothing to compare).

## The lints

The two **advisory warnings** below (`severity = "warning"`) never block a
`check`; they surface a hazard with the node name and the offending grants so an
author can tighten the graph or consciously accept the shape. They sit alongside
the **POLA use-check error** (`E-CAP-USE`, `severity = "error"`), which *does*
block — exercising authority a node does not hold is unsound, not merely
imprudent.

### `E-CAP-USE` (the POLA use-check)

`needs` declares the capabilities a node **uses** (`used(p)`, 0011 §4.3). The
use-check requires `used(p) ⊑ granted(p)`: for each declared `(domain,
need_grant)`, the node must hold some grant `g` in the **same domain** with
`need_grant ≤ g` under that domain's attenuation order (a stronger held grant
authorizes a weaker use). If no held grant in the domain dominates the need — the
node holds nothing in the domain, or only weaker grants — the node is
*underpowered*: it exercises authority it does not hold. Emit `E-CAP-USE`
(severity `error`) against the node's `needs` field, naming the node, the
exercised `domain.grant`, and the held grants (or `(none in domain <d>)`).

This is the **dual** of `W-POLA-EXCESS` and orthogonal to it per domain:
`W-POLA-EXCESS` fires when a held grant is *stronger* than every declared need
(granted > needed — a warning); `E-CAP-USE` fires when a declared need is not
dominated by any held grant (needed > held — an error). One node can raise both,
in different domains. A node that declares no `needs` opts out of both (no
declared `used` set ⇒ nothing to check).

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

### `E-EGRESS-USE` & `W-EGRESS-UNREFINED` (network-membrane POLA)

The **network-domain dual** of `E-CAP-USE` / `W-POLA-EXCESS`. A `networkMembrane`
refines a principal's `network` grant into a concrete `allow = [egress(host, port)]`
set; the membrane must not authorize egress the capability graph never granted.

- **`E-EGRESS-USE`** (`severity = "error"`) — for each membrane, classify every
  `allow` host to the network lattice level it implies (`none < loopback < lan <
  egress`): a loopback host/IP → `loopback`; a private IP → `lan`; any other IP or a
  DNS name → `egress`. If the principal's strongest held `network` grant does **not**
  dominate the strongest required level — or the `principal` names no node in the mesh
  — the membrane authorizes egress beyond the granted capability, which is unsound:
  emit `E-EGRESS-USE`. This is the membrane-side analog of `E-CAP-USE`'s
  `used ⊑ granted` (here: *allowed ⊑ granted*).

- **`W-EGRESS-UNREFINED`** (`severity = "warning"`) — a node holds `network.egress`
  or `network.lan` with **no** `networkMembrane` refining it: its egress is unbounded.
  Advisory (the dual of `W-POLA-EXCESS`); never blocks. Add a `network` membrane with
  an `allow` set to scope it.

Host classification uses the stdlib `ipaddress` order; deterministic (membranes and
nodes sorted by name). This promotes the oracle's tool-local egress drift-check
(`tools/oracle/roster_from_vaked.check_roster_egress`, slice-4b thread 1) to a
first-class language pass.

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
- `vaked/examples/types/cap-use-*.vaked` — the `E-CAP-USE` fixtures (Risk 6):
  seven negative cases (underpowered, no-caps, wrong-domain, partial, two-node,
  and combos with `W-POLA-EXCESS` / `E-CAP-ATTENUATION`) plus `cap-use-no-needs`,
  the opt-out proof (a cap-holding node with no `needs` stays clean).
- `vaked/examples/types/egress-*.vaked` — the `E-EGRESS-USE` fixtures:
  `egress-use-exceeds` (membrane allows public egress for a `loopback`-only
  principal), `egress-use-bad-principal` (membrane principal names no node),
  `egress-use-ok` (egress grant covers a public-egress cordon, clean), and
  `egress-unrefined` (an unrefined egress grant → one `W-EGRESS-UNREFINED`).

## Status

- ✅ Per-node held authority + declared `needs` from the mesh.
- ✅ `W-POLA-EXCESS` and `W-CONFUSED-DEPUTY` warnings with node names + offending
  grants/edges.
- ✅ `E-CAP-USE` use-check error (Risk 6, 0011 §4.3): a node may not exercise (via
  `needs`) authority no held grant dominates; the dual of `W-POLA-EXCESS`.
- ✅ `E-EGRESS-USE` error + `W-EGRESS-UNREFINED` warning: the network-membrane POLA
  pass (allowed ⊑ granted) — a `networkMembrane` may not authorize egress beyond its
  principal's `network` grant; an unrefined egress grant is flagged advisory.
  Promotes the oracle's tool-local egress check to a language pass.
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

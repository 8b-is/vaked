# 0028 — Network-membrane POLA: the egress-use rule & vakedz parity

**Status:** implemented in `vakedc` (PR #282); `vakedz` parity is a planned cycle (this note specs it).
**Depends on:** [0026 — capability reachability & POLA](./0026-capability-reachability-pola.md),
[0027 — POLA formalization (Lean)](./0027-pola-formalization.md).

## Abstract

`E-CAP-USE` (0026 §`The lints`) enforces the POLA use-check on the **capability** layer —
`used(p) ⊑ granted(p)`: a node may not *exercise* (via `needs`) authority no held grant
dominates. This note formalizes the **network-membrane** dual on the **egress** layer —
`allowed(m) ⊑ granted(principal(m))`: a `networkMembrane` may not *authorize* egress beyond
its principal's held `network` grant. Two diagnostics realize it: **`E-EGRESS-USE`** (error)
and **`W-EGRESS-UNREFINED`** (advisory warning). It is the language-level promotion of the
oracle's tool-local egress drift-check (`tools/oracle/roster_from_vaked.check_roster_egress`,
slice-4b thread 1).

## The network lattice

The builtin `network` capability domain is a chain (`vaked/schema/builtins.vaked`):

```
none < loopback < lan < egress
```

A `networkMembrane` refines a principal's grant into a concrete allow-set of
`egress(host, port)` rules (deny-by-default). Each allow **host** classifies to the lattice
level it *requires* of the principal, via `host_level : Host → {loopback, lan, egress}`:

- `host` is a loopback name/IP (`localhost`, `127.0.0.0/8`, `::1`) ⇒ `loopback`
- `host` is a private IP (`is_private`: `10/8`, `172.16/12`, `192.168/16`, ULA …) ⇒ `lan`
- any other IP, **or a DNS name** ⇒ `egress` (conservative: an unresolvable name is treated
  as public)

`required(m) = ⨆ { host_level(h) | egress(h, _) ∈ allow(m) }` (the join / strongest level).

## The rule

Let `held(p) = ⨆ { g | (network, g) ∈ grants(p) }` (the principal's strongest network grant;
`none` if it holds none).

**`E-EGRESS-USE`** (severity `error`) holds for membrane `m` with principal `p` iff:

```
principal(m) ∉ nodes(mesh)              ∨    ¬ ( required(m) ⊑ held(principal(m)) )
```

i.e. the membrane names no real node, **or** it allows egress at a level the principal's
network grant does not dominate — the membrane authorizes connections the capability graph
never granted. This is *unsound*: the lowered eBPF policy (`agent_guardd`) would enforce an
allow-set the principal was never entitled to.

**`W-EGRESS-UNREFINED`** (severity `warning`, advisory — never blocks) holds for node `n` iff:

```
held(n) ∈ {lan, egress}    ∧    ¬∃ m. principal(m) = n
```

i.e. `n` holds non-trivial egress authority with **no** refining membrane — its egress is
*unbounded*. The dual of `W-POLA-EXCESS` (held > needed): here the grant is held but never
scoped. `loopback`/`none` need no membrane (already narrowest).

## Soundness

The rule is the membrane-side instance of the same order-theoretic obligation 0027 mechanizes
for `E-CAP-USE`. Where `E-CAP-USE` proves `used ⊑ granted`, `E-EGRESS-USE` proves
`allowed ⊑ granted` over the **same** `network` attenuation order. Because `host_level` is
monotone into the lattice and `required` is the join, a graph that passes `E-EGRESS-USE` admits
**no** membrane whose allow-set exceeds its principal's grant — so the lowered egress policy is a
sub-policy of the granted authority. (A Lean obligation mirroring 0027 §`Key lemmas`, with
`host_level`/`required` as the new definitions, is a follow-up; the proof shape is identical to
the cap-use lemma.)

### Deny-by-default & the lower-time DNS gap (honest scope)

Two layers, intentionally distinct:
- **Language layer (this rule):** hostname-aware — `required` classifies DNS names to `egress`,
  so the check is sound for `egress("openrouter.ai", 443)`.
- **Packet layer (`agent_guardd` / `0012` lowering):** IP-literal only. The `0012` emitter
  **drops** a non-IP `egress(host, …)` rule (no CIDR for a DNS name) → the lowered membrane is
  deny-all for that host. So an `openrouter.ai` cordon is enforced at the **tool layer**
  (`roster_from_vaked.check_roster_egress`), not the packet layer. The language check and the
  packet enforcer agree on IP rules; on DNS rules the language check is the binding one. Closing
  the packet gap needs a pinned-IP egress proxy (tracked separately).

## Implementation status

- **`vakedc`** (Python front-end): shipped (PR #282). `_check_egress_use` in `vakedc/check.py`;
  fixtures `vaked/examples/types/egress-*.vaked`; tests in `tests/spec/test_vakedc_check.py`.
  Corpus-safe: the rule adds **zero** errors to the example corpus (no example over-reaches a
  membrane); 10 unrefined-egress examples gain the advisory warning. `oracle-team.vaked` is
  clean (PR #283 cordoned its operator/coordinator).

## vakedz parity (planned cycle — this note is its spec)

`vakedz/src/check.zig` (the Zig front-end) currently implements the type system, schema
conformance, capability-domain validation, capability-ref checks, the per-node **node-grant map**
(`checkMesh`), the lattice **`leqGrant`**, and **edge attenuation** (`E-CAP-ATTENUATION`) — but
**not** the `needs`-based POLA use-check (`E-CAP-USE`), `W-POLA-EXCESS`, `W-CONFUSED-DEPUTY`, or
membrane/network handling. Porting `E-EGRESS-USE` in isolation is incoherent; the parity work is
the **whole reachability layer** as one WP.

### Prerequisite blockers (found 2026-06-16 — must clear before the port verifies)

A timeboxed attempt added an additive `E-CAP-USE` loop to `checkMesh` (it compiled clean and
`zig build test` stayed green — no regression), but it could **not** be verified end-to-end, for
two pre-existing reasons the parity cycle must fix **first**:

- **A — parser-parity gap (blocking all `check`).** `vakedz parse vaked/schema/builtins.vaked`
  fails: `parse error: expected operator` at **`builtins.vaked:91:33`**. Because `vakedz check`
  loads `--builtins` (default `vaked/schema/builtins.vaked`) and aborts if it can't parse it, the
  CLI checker is currently **non-functional on the live builtins** — no fixture can be checked
  through the real path until the vakedz parser is brought up to the builtins' current syntax.
- **B — top-level-mesh check wiring.** With a minimal stub builtins (to bypass A),
  `vakedz check --json` on the top-level-mesh fixture `cap-use-partial.vaked` returned
  `{"diagnostics": []}` — the additive `E-CAP-USE` did **not** fire. The `cap-use-*` fixtures are
  **top-level** meshes (not runtime-nested); confirm `checkMesh` (and thus the reachability pass)
  is actually invoked on a top-level `mesh` decl, or wire it so it is. vakedc's `check_source`
  checks top-level meshes; vakedz must match.

With A and B cleared, the WP is, in order:

1. **Node-grant map + lattice `leq`** — build `{node → [(domain, grant)]}` from `mesh` node
   `capabilities` (the capability parsing at `check.zig:1083` already extracts these); reuse the
   `CapabilitySpec` order (`capabilityFromDecl`) for a `leq(cap, a, b)` helper.
2. **`E-CAP-USE` + `W-POLA-EXCESS` + `W-CONFUSED-DEPUTY`** — port 0026's reachability pass
   (needs the mesh edge list + `needs` extraction).
3. **`E-EGRESS-USE` + `W-EGRESS-UNREFINED`** — iterate sibling `network` (membrane) decls,
   read `principal`/`allow`, classify hosts (`std.net.Address.parseIp` + a private/loopback
   predicate; a non-IP host ⇒ `egress`), compare `required` to `held` via the `leq` helper.
4. **Parity fixtures** — the same `vaked/examples/types/{cap-use,egress}-*.vaked` must yield the
   **identical** diagnostic code-sets under both front-ends (a cross-front-end conformance test).

The acceptance bar: `vakedz check` and `vakedc check` emit the same diagnostic codes on the
shared fixtures — the determinism/parity contract the cache-native port is built to honor.

## References

- 0026 — capability reachability & POLA (the design + `E-CAP-USE`/`W-POLA-EXCESS`).
- 0027 — POLA formalization (the Lean soundness argument this rule extends).
- `tools/oracle/roster_from_vaked.py` — the tool-local egress check this rule promotes.
- `agent_guardd/policy.py` — the packet-layer egress enforcer (IP-literal, deny-by-default).

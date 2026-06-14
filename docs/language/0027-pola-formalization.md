---
doc: 0027
title: "POLA formalization — mechanizing the §4.5 soundness argument in Lean 4"
status: Draft (deferred)
track: Language
created: 2026-06-14
---

# 0027 — POLA formalization: mechanizing the §4.5 soundness argument in Lean 4

Status: **Draft (deferred)** · Series: language design notes · Track: Language

## Abstract

0011 §4.5 gives an **informal**, hand-written argument that the Vaked POLA check
is sound: any capability a principal can exercise is bounded by the grants held by
its upstream delegators, so authority is non-increasing along delegation paths.
This note plans the **mechanization** of that argument as a machine-checked proof
in **Lean 4 + Mathlib**. The scope is deliberately *spec-level*: we formalize the
abstract model (the capability partial order, the grant-set preorder, the
attenuation and use rules) and prove the top-level POLA invariant as a theorem
over that model. We do **not** attempt to prove that the implementation
(`vakedc/check.py`) faithfully realizes the model, nor anything about runtime
enforcement. The deliverable is a Lean development that turns §4.5 from prose into
a checked theorem, closing the gap between the paper's "POLA at compile time"
claim and what is actually verified today.

This work is **deferred**: it is scaffolded here so the claim-honesty fixes in
0011 §4.5, the paper abstract, and `THREAT_MODEL.md` can reference a concrete plan
(RFC 0027) rather than an open promise. It is **not** scheduled until its
prerequisite (below) lands.

## Motivation

The trunk currently **overclaims**:

- 0011 §4.5 previously read "the check **is sound**" with no hedge.
- The paper abstract previously read the type system "**enforces** POLA."
- `THREAT_MODEL.md` itself states that runtime enforcement is **not** guaranteed,
  and §4.1 lists "bugs in the Vaked type checker" as an unmitigated risk.

No machine-checked proof exists. The honest position — now reflected in 0011 §4.5,
the abstract, and `THREAT_MODEL.md` — is that POLA soundness rests on an *informal*
argument. A mechanized proof would:

1. **Substantiate the central security claim.** "POLA at compile time" is the
   paper's headline contribution; a checked theorem makes it defensible.
2. **Find argument bugs.** Mechanization routinely surfaces missing side
   conditions (e.g. the cyclic-mesh equality case, the same-domain requirement on
   `⊑`) that prose glosses over.
3. **Pin the model.** A Lean datatype for grant-sets and the order relation forces
   the abstract semantics to be stated precisely once, as a reference other docs
   (0011, 0026, the paper) cite.

## Scope

**In scope (spec-level model + proof):**

- The per-domain attenuation relation `≤` as a **partial order** (the
  reflexive–transitive closure of declared `<`, with antisymmetry from acyclicity)
  — 0011 §4.2.
- The grant-set authorization relation `⊑` as a **preorder** over grant-sets
  (reflexive, transitive; same-domain domination) — 0011 §4.3/§4.4.
- The **path-attenuation induction lemma**: along any delegation path `s ->* r`,
  `granted(r) ⊑ granted(s)`.
- The **cyclic-case antisymmetry lemma**: a `⊑`-cycle forces grant-set equality
  (the mesh-cycle degeneration in §4.5 / `THREAT_MODEL.md` Scenario D).
- The **top POLA theorem**: any exercised capability is bounded by the root grant.

**Out of scope (explicitly not proven here):**

- **Faithfulness of `vakedc/check.py`** (and `vakedz`) to the Lean model — i.e. that
  the implementation computes exactly the modeled relations. This is a separate
  refinement/extraction effort; the risk it covers stays in `THREAT_MODEL.md` §4.1.
- **Runtime enforcement** — membranes, syscall filtering, revocation (Zig daemons +
  eBPF). Out of scope per 0011 §Scope; mechanizing the *static* model says nothing
  about the running system.

## Prerequisite (blocking)

**`E-CAP-USE` must be implemented and negative-tested before this RFC starts.**
The §4.5 argument composes the **use check** (§4.3) with the **attenuation check**
(§4.4); the top theorem is vacuous if the use check is not actually enforced.
Mechanizing a model of a rule the compiler does not run would be misleading.
Tracked as **Risk 6 / `feat/cap-use-check`**. Until `E-CAP-USE` is implemented and
has negative tests (cases that *must* be rejected, and are), RFC 0027 stays
deferred.

## Datatypes (sketch)

A first-cut Lean 4 model. Names are indicative, not final.

```text
Domain      -- an enumeration / opaque type of capability domains (fs, network, …)
Grant       -- a (Domain, label) pair: a single capability domain.grant
GrantSet    -- a finite set of Grant
Principal   -- an opaque id (node / fiber / surface)
MeshEdge    -- a directed delegation edge (Principal × Principal)
```

- The per-domain order is a relation `le : Domain → Grant → Grant → Prop`, assumed
  to be a `PartialOrder` on the grants of each fixed domain (from §4.2
  acyclicity).
- `granted : Principal → GrantSet` and `used : Principal → GrantSet` are the model
  inputs.
- `⊑` (`authorizes`) is defined on `GrantSet × GrantSet` (and on `Grant × GrantSet`)
  via same-domain domination.
- A `Mesh` is a finite set of `MeshEdge`; `s ->* r` is the reflexive–transitive
  closure (`Relation.ReflTransGen`).

## Key lemmas

| Lemma | Statement | Proof sketch |
|-------|-----------|--------------|
| `attenuation_partial_order` | For each domain, `le dom` is a partial order. | From §4.2: refl/trans by closure construction; antisymmetry by acyclicity of declared `<`. In Lean, derive a `PartialOrder` instance from the acyclic `<` (well-founded ⇒ antisymmetric). |
| `grantset_preorder` | `⊑` is a preorder on `GrantSet`. | Reflexivity: each grant dominates itself (refl of `le`). Transitivity: chain same-domain dominations using `le`-transitivity; `Preorder` instance. |
| `path_attenuation` | If `s ->* r` then `granted r ⊑ granted s`. | Induction on `ReflTransGen`: base case refl (`⊑`-refl); step case composes the per-edge attenuation hypothesis with `⊑`-transitivity. |
| `cyclic_case` | If `s ->* r` and `r ->* s` then `granted r = granted s`. | Two applications of `path_attenuation` give `⊑` both ways; antisymmetry of the lifted order on grant-sets ⇒ equality (the mesh-cycle degeneration). |

## Top theorem

```text
theorem pola_invariant :
  -- given: per-edge attenuation holds for every mesh edge,
  --        and the use check holds for every principal,
  -- for any principal p, any capability c ∈ used p, and any upstream
  -- delegator a with a ->* p:
  --   ∃ g ∈ granted a, same_domain g c ∧ le _ c g
  -- i.e. every exercised capability is ≤ a grant held by every ancestor,
  --      hence bounded by the root grant and non-increasing along paths.
```

Proof composes `path_attenuation` (authority bounded by each ancestor) with the
use-check hypothesis (`used p ⊑ granted p`) and `⊑`/`le` transitivity. This is the
mechanized counterpart of the "composing 2 and 3" paragraph in 0011 §4.5.

## Tool choice

**Lean 4 + Mathlib.** Rationale:

- **Mathlib supplies the order theory off the shelf** — `PartialOrder`, `Preorder`,
  `Relation.ReflTransGen`, finite sets, and antisymmetry-from-well-foundedness —
  which is exactly the algebra §4.5 leans on. Little bespoke library is needed.
- **Active, maintained, and proof-stable** for this style of relational
  combinatorics; good automation (`decide`, `omega`, `aesop`) for the finite,
  decidable side conditions that mirror the checker's totality.
- **Alternatives considered.** Coq + stdpp/mathcomp is equally capable and was named
  as an option in the paper's future-work list; Lean 4 is chosen for the lighter
  order-theory ramp via Mathlib and the smaller proof surface. Agda and Isabelle/HOL
  are viable but offer no advantage for this specific, order-theoretic obligation.

The development is **spec-only**: no extraction to executable code and no attempt to
connect Lean terms to `vakedc` Python (that is the out-of-scope faithfulness step).

## Effort

**2–4 person-weeks** for someone fluent in Lean 4 + Mathlib:

- ~3–5 days: model datatypes, `le`/`⊑` definitions, the two order instances.
- ~3–5 days: `path_attenuation` + `cyclic_case` over `ReflTransGen`.
- ~2–4 days: `pola_invariant`, polish, and a short note mapping each Lean lemma back
  to its §4.5 prose step.

Risk skews longer if the chosen `GrantSet`/domain encoding fights Mathlib's order
typeclasses; budget the upper bound. This estimate excludes the prerequisite
`E-CAP-USE` work, which is tracked separately (Risk 6).

## References

- 0011 §4 (capabilities: taxonomy + attenuation), §4.5 (the informal soundness
  argument this RFC mechanizes), §6.4 (totality/termination argument) —
  [`0011-type-system.md`](./0011-type-system.md)
- [`THREAT_MODEL.md`](./THREAT_MODEL.md) — POLA guarantee, scope, and the
  type-checker-bug risk (§4.1) this work does *not* close
- [`0026-capability-reachability-pola.md`](./0026-capability-reachability-pola.md)
  — graph-level POLA/confused-deputy lints over the same authority graph
- Lean 4 + Mathlib order theory (`PartialOrder`, `Preorder`,
  `Relation.ReflTransGen`)

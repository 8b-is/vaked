---
doc: 0018
title: "crypto/seal — the cryptographic capability domain"
status: Draft
track: Language
created: 2026-06-13
---

# 0018 — `crypto`/`seal`: the cryptographic capability domain

Status: **Draft** · Series: language design notes · Track: Language

## Abstract

RFC 0007 §"Open questions" Q4 asks whether suite selection and votive-seal
authority should be a first-class Vaked capability domain, declared in the graph
and lowered into the spine, rather than being a protocol property alone. This note
proposes exactly that: a new `crypto` kind that pairs a named algorithm suite with
a signing-authority grant, attenuated by the same POLA ordering as `mem`/`fs`.
Making cryptographic posture a *language* property — not just a protocol property —
means the checker can enforce "encryption baked in" before any artifact is emitted,
and the lowering pass can wire suite selection and votive-seal authority into the
runtime spine automatically.

## Motivation

RFC 0007 establishes three disciplines: a post-quantum wire layer (§3), PQC identity
and votive seals (§4), and image-as-code attestation (§5). All three are currently
**protocol** properties: they are described in the wire protocol and the identity
distribution RFC, and they emerge from runtime behavior. Nothing in the Vaked
language enforces them at declaration time.

The cost of this gap is real. A `network` membrane can today be declared and
lowered without any statement about its cryptographic posture. The lowering pass
emits a `provenance.json` (0012 §6), but there is no checker rule that rejects a
membrane with no votive-seal authority, or one that names a classical-only suite
in a cross-host context. The "encryption baked in" principle (RFC 0007 §"Design
principles", #1) is aspirational at the language level; it is only enforced at
the protocol level.

The **image-as-code** principle (RFC 0007 §5) sharpens this further. The only
mutation path to a running system is a code change that re-derives and re-signs
the image. If the signing authority and algorithm suite are not declared in the
graph, there is no way for the checker to verify that a membrane's provenance chain
is complete, or that the suite it will be signed with meets the deployment's
post-quantum requirements.

Q4 from RFC 0007 §"Open questions" states this directly:

> "Should suite selection and votive-seal authority be a first-class Vaked
> capability domain (POLA-attenuated like `mem`/`fs`), declared in the graph and
> lowered into the spine? This would make 'encryption baked in' a *language*
> property, not just a protocol one — worth a separate language-track note before
> any grammar change."

This is that note.

## The `crypto` kind

A `crypto` declaration binds a named algorithm suite to a votive-seal signing
authority, and grants those capabilities to membranes that reference it. Like
`capability fs` and `capability mem`, a `capability crypto` domain declares an
attenuation partial order over grants (`none < sign < seal < admin`). Unlike those,
a `crypto` *kind* declaration also carries two new fields: `suite` (the named
algorithm suite) and `seal` (the signing authority identity that will issue votive
seals for artifacts materialized under this declaration).

### Proposed syntax

```vaked
# Declare the crypto capability domain (mirrors fs, mem in parallel-types.md).
# This lives in the built-in catalog; users extend it with new suite names,
# not with new grants.
capability crypto {
  grant none sign seal admin
  order none < sign < seal < admin
}

# A crypto kind declaration names a suite and a seal authority.
# It is the unit of cryptographic posture: one declaration per membrane
# (or shared across a mesh when the posture is uniform).
crypto pq-default {
  suite = "hybrid-ml-kem-768"        # KEM: X25519 + ML-KEM-768 (RFC 0007 §3)
  seal  = "ml-dsa-65"                # votive-seal signer: ML-DSA-65 (RFC 0007 §4)
}
```

Field semantics:

| Field | Type | Required | Semantics |
|-------|------|----------|-----------|
| `suite` | `String` | yes | Named algorithm suite, as a versioned token. Determines KEM, AEAD, and transcript-signature algorithm for the wire layer. The checker validates against a closed `oneof` of known suite tokens (§ Checker integration). |
| `seal` | `String` | yes | Named signing algorithm for votive seals. Independently versioned from the KEM suite. The checker validates against a closed `oneof` of known seal tokens. |
| `hybrid` | `Bool` | optional, default `true` | If `true`, the suite is a hybrid (classical + PQC) construction; if `false`, the deployment is PQC-only. Checked against the `pq-required` negotiation posture (§ Open questions). |
| `root-algorithm` | `String` | optional | Override for the trust-domain root signature algorithm. Defaults to `"slh-dsa"` (RFC 0007 §4 — hash-based, for long-lived roots). |

### Known suite tokens (initial closed set)

| Token | KEM | AEAD | Transcript signature | Status |
|-------|-----|------|----------------------|--------|
| `"hybrid-ml-kem-768"` | X25519 + ML-KEM-768 | ChaCha20-Poly1305 | hybrid Ed25519 + ML-DSA-65 | Default (RFC 0007 §3) |
| `"ml-kem-768"` | ML-KEM-768 only | AES-256-GCM | ML-DSA-65 only | PQC-only deployments |
| `"classical-x25519"` | X25519 only | ChaCha20-Poly1305 | Ed25519 only | Migration / local-only; refused cross-host |

### Known seal tokens (initial closed set)

| Token | Algorithm | Notes |
|-------|-----------|-------|
| `"ml-dsa-65"` | ML-DSA-65 (FIPS 204) | Default votive-seal signer |
| `"hybrid-ed25519-ml-dsa-65"` | Ed25519 + ML-DSA-65 | Migration hybrid |
| `"slh-dsa"` | SLH-DSA (FIPS 205, SPHINCS+) | Long-lived roots only |

### Attenuation grants

```
none < sign < seal < admin
```

| Grant | Meaning |
|-------|---------|
| `none` | No cryptographic authority — cannot sign anything. A membrane declared without any `crypto` grant implicitly holds `crypto.none` (checked). |
| `sign` | May sign artifacts it produced (e.g. a fiber signing its own output streams). Cannot issue votive seals over other agents' images. |
| `seal` | May issue votive seals — the primary grant for the deployment plane (`agent-supervisord`). Holds `sign` by attenuation. |
| `admin` | May retire suite tokens and record a `crypto_suite` bump to `eventd`. Only the control plane holds `admin`. |

### Referencing a `crypto` declaration

A `network` membrane (or any membrane) references a `crypto` declaration by name,
and the mesh delegates the appropriate grant:

```vaked
network edge-membrane {
  crypto = crypto.pq-default          # bind this membrane to the pq-default posture
  capabilities = [crypto.seal, network.egress]
}

mesh field {
  node spine {
    capabilities = [crypto.admin, fs.host_rw]
  }
  node edge {
    capabilities = [crypto.seal, network.egress]
  }
  spine -> edge : "delegate"
  # Checker: crypto.seal <= crypto.admin (attenuation holds)
  # Checker: network.egress <= network.egress (same grant, trivially ok)
}
```

## Example: a sealed network membrane

The following is the minimal complete example. The `crypto.pq-default` declaration
supplies the suite and seal authority; the `network edge` membrane references it;
the mesh delegates `crypto.seal` with attenuation from the spine.

See [`vaked/examples/types/crypto.vaked`](../../vaked/examples/types/crypto.vaked)
for the worked example file.

## Checker integration (0011)

Two new checker rules:

### `E-CRYPTO-SUITE-UNKNOWN`

A `crypto` declaration whose `suite` field value is not in the known suite token
set raises `E-CRYPTO-SUITE-UNKNOWN`. This is a closed constraint — like `oneof` on
a schema field — enforced at elaborate-time (0011 §5 elaboration pass). New suite
tokens require a grammar-track note and a parallel-types.md update.

### `E-CRYPTO-SEAL-UNKNOWN`

Symmetric: `seal` not in the known seal token set raises `E-CRYPTO-SEAL-UNKNOWN`.

### `E-CRYPTO-NONE-CROSS-HOST`

A `network` membrane whose declared crypto grant is `crypto.none` and whose network
grant is `network.egress` (cross-host) raises `E-CRYPTO-NONE-CROSS-HOST`. This is
the checker encoding of "encryption baked in": a membrane that can reach egress
**must** declare at least `crypto.sign`. This rule is checked during the capability
flow pass (0011 §4.3).

### Attenuation

Attenuation over `crypto` follows the same `E-CAP-ATTENUATION` rule as all other
capability domains (0011 §4.4). A mesh node delegating `crypto.seal` to a
subordinate that holds only `crypto.sign` is valid; the reverse is rejected.

## Lowering (0012)

The `crypto` kind gets its own emitter slot in the 0012 §3.4 registry:
`crypto.spine`. The emitter is output-first: what does it produce?

| Artifact | Path | Contents |
|----------|------|----------|
| **Crypto spine config** | `gen/crypto/<name>.json` | Suite token, seal algorithm, hybrid flag, root-algorithm override, and the per-runtime eventd log path (so suite-bump events are recorded). Consumed by the runtime plane at image-admit time. |
| **Votive-seal authority record** | `gen/crypto/<name>.seal.json` | The seal grant holder's SPIFFE ID (resolved from the mesh node holding `crypto.seal`), the suite token, and the topology epoch — the inputs to the votive-seal signature described in RFC 0007 §4. |
| **eventd suite-bump contract** | `gen/eventd.json` (extended) | A `crypto_suite_bump` contract entry: the event shape that a `crypto.admin` holder must record when retiring a suite token. Shape: `{ old_suite, new_suite, topology_epoch, signed_by: crypto.admin-holder }`. This is the `eventd` side of RFC 0007 §6's "retirement is a recorded parameter change." |
| **provenance annotation** | `.vaked/provenance.json` (extended) | The `crypto` decl name and suite token are added to the provenance record emitted by 0012 §6, so every artifact's provenance carries its cryptographic posture. |

The emitter does **not** perform key generation, signing, or network operations.
Those are runtime effects. The emitter produces the *configuration* that tells the
runtime plane which suite to use and which identity to authorize for votive-seal
issuance.

### Relationship to 0012 §5 (Nix spine)

The `gen/crypto/<name>.json` artifact is added to the Nix spine as a
`config.<name>-crypto` overlay — a NixOS module that sets the suite parameter for
the relevant runtime service. The Nix build is hermetic; the suite token is a pure
string, so the same source yields the same module output on any machine.

## Open questions

### Q1: Suite negotiation and `REFUSE{pq-required}` (RFC 0007 §3)

RFC 0007 §3 defines a `crypto_suite` negotiation field in the wire preamble.
An initiator offering only classical suites is refused with `REFUSE{pq-required}`
on cross-host connections. How does the checker's `E-CRYPTO-NONE-CROSS-HOST` rule
interact with this?

**Option A (current lean):** The checker rule is conservative — it flags
`crypto.none` on egress membranes at declaration time, regardless of the wire's
runtime negotiation. This gives the earliest possible signal (check-time, not
runtime) and means the checker's refusal *precedes* the wire's `REFUSE`. The
runtime `REFUSE{pq-required}` becomes defense-in-depth, not the primary gate.

**Option B:** The checker only warns (not errors) when `crypto.none` is used with
egress, and defers to the wire's `REFUSE{pq-required}` as the enforcement point.
This is more flexible but pushes enforcement later — against the spirit of
"Validate before generating."

**Option C:** The `hybrid = false` flag on a `crypto` decl triggers
`E-CRYPTO-CLASSICAL-CROSS-HOST` (a stricter variant of the rule) for classical-only
suites used with egress, while `hybrid = true` is always acceptable because the
hybrid construction is secure if either half holds.

Resolution requires input from the protocol track (RFC 0007 §3 negotiation
semantics vs. the checker's posture). Lean: Option A, with Option C as the
migration path.

### Q2: Suite-bump ceremony

When `crypto.admin` retires a suite token (recording a `crypto_suite_bump` to
`eventd`), how does the deployed runtime gate the transition? Does
`agent-supervisord` refuse images sealed with the old suite before the bump is
recorded, or after? This is a runtime sequencing question (eventd ordering) that
the emitter does not need to resolve, but the `eventd` contract shape must not
foreclose it.

### Q3: Per-membrane vs. per-runtime posture

Should a runtime declare a single `crypto` posture (shared by all its membranes)
or per-membrane postures? The current proposal allows both: a `crypto` decl
referenced from a single `network` membrane is per-membrane; a `crypto` decl
referenced from a `runtime` block is the default for all membranes that do not
override it. The checking rule for "no override = inherit runtime default" is not
yet specified.

### Q4: SPIRE PQC support shim

RFC 0007 §"Open questions" Q3 asks whether the SPIRE deployment issues ML-DSA
SVIDs natively or needs a hybrid-cert shim. The answer affects whether the
`seal = "ml-dsa-65"` token maps directly to a SPIRE-issued credential or requires
a shim layer in the runtime plane. This is an implementation question; the language
declaration is agnostic to the shim.

## Next step

This note is step 0 of the `crypto`/`seal` capability domain: the design, the
syntax proposal, and the checker/lowering contracts. The follow-up cycle:

1. **Grammar change** — add `"crypto"` to the `kind` production in
   `vaked/grammar/vaked-v0-plus.ebnf` and file a GitHub issue for the versioned
   language change (per CLAUDE.md convention: grammar before code).
2. **parallel-types.md update** — add the `capability crypto` domain and the
   `schema crypto` record to the built-in catalog.
3. **Checker** — implement `E-CRYPTO-SUITE-UNKNOWN`, `E-CRYPTO-SEAL-UNKNOWN`, and
   `E-CRYPTO-NONE-CROSS-HOST` in `vakedc/check.py`.
4. **Lowering** — add the `crypto.spine` emitter slot to 0012 §3.4 and implement
   `gen/crypto/<name>.json`.
5. **Spike** — per RFC 0007 Q5: lower one `network` membrane with `crypto.pq-default`,
   PQC-sign its provenance, and verify a measured admit/refuse.

## Cross-references

- [RFC 0007](../../protocol/rfcs/0007-post-quantum-litany-sealed-image.md) — PQ
  wire layer (§3), votive seals (§4), image-as-code attestation (§5), Open Q4 (§"Open questions")
- [0011 — Type system](./0011-type-system.md) — capability attenuation rules (§4),
  checking pipeline (§6); new checker codes (`E-CRYPTO-*`) extend §4.4
- [0012 — Lowering](./0012-lowering.md) — emitter registry (§3.4), provenance
  record (§6); `crypto.spine` is a new emitter slot
- [0014 — memory primitive](./0014-memory-primitive.md) — the `mem` domain is the
  closest design precedent: a capability domain (`capability mem`) paired with a
  new kind (`memory`) and its own emitter slot
- [0016 — Substrate candidates](./0016-substrate-candidates.md) — PQC listed as a
  `reference` candidate; this note is the trigger for promotion to default
- [RFC 0006](../../protocol/rfcs/0006-transport-identity-distribution.md) —
  SPIFFE/SPIRE identity; PQC SVIDs are the credential type that `seal = "ml-dsa-65"`
  maps to

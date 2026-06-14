---
doc: 0022
title: "MLIR Pass 2 — write-ahead registration injection"
status: Review
track: Language / MLIR
created: 2026-06-14
issue: 23
epic: 17
---

# 0022 — Pass 2: automatic write-ahead registration injection

Status: **Review** (2026-06-14) · Series: language design notes · Track:
**Language / MLIR** · Issue
[#23](https://github.com/peterlodri-sec/vaked-base/issues/23) · Epic
[#17](https://github.com/peterlodri-sec/vaked-base/issues/17)

Part of the MLIR set; umbrella in
[0013](./0013-mlir-topology-compilation.md). **Inputs:** the `vaked` dialect
([0019](./0019-mlir-vaked-dialect.md)) and the `hcp` dialect
([0020](./0020-mlir-hcp-dialect.md)). **Protocol anchor:**
[RFC 0004](../../protocol/rfcs/0004-multi-agent-state-dependency.md) §3 (write-ahead
discipline). **Stage-0 reference:** `vakedc/lower.py` (`emit_workflow_spec`).

## Abstract

Pass 2 is the `vaked → hcp` lowering. It replaces every `vaked.consume` with the
`hcp` write-ahead sequence — `create_registration_token → write_ahead_log →
fetch_canonical_data` — and encloses the dependent computation in an
`hcp.rewind_scope`. The point is to make RFC 0004's write-ahead discipline
**structural and generated**: a hand-written `DependencyRegistration` is a
conformance smell (RFC 0004 §3.1), so the compiler writes it, every time,
correctly ordered.

## 1. The rewrite

For each `vaked.consume {producer = @A, producer_step = N}` in consumer agent
`@B`, producing `%in : !vaked.state_hash`:

```mlir
// before
%in = vaked.consume { producer = @A, producer_step = 15 : i64 } : !vaked.state_hash
... uses of %in ...

// after (Pass 2)
%h       = vaked.state_anchor @A, 15            // the anchored producer hash (see §1.1)
%token   = hcp.create_registration_token {
             producer = @A, producer_step = 15 : i64, topology_epoch = %epoch
           } %h : (!vaked.state_hash) -> !hcp.reg_token
%receipt = hcp.write_ahead_log %token            : (!hcp.reg_token) -> !hcp.wal_receipt
%data    = hcp.fetch_canonical_data %receipt     : (!hcp.wal_receipt) -> !hcp.canonical_data
hcp.rewind_scope { producer = @A } {
  ... uses of %in, now reading %data ...
  hcp.yield ...
}
```

`%in`'s uses are rewired to `%data`. The three ops are emitted **in order**, and
because `fetch_canonical_data` data-depends on the `write_ahead_log` receipt
([0020](./0020-mlir-hcp-dialect.md) §4), no later pass can reorder the fetch
ahead of the log.

### 1.1 The anchored hash

The `producer_step_hash` operand of `hcp.create_registration_token` is the
producer's step-`N` output hash. At compile time this is symbolic — the concrete
eventd hash is known at runtime — so Pass 2 references it via the producing
`vaked.agent`'s step result (an internal `vaked.state_anchor @A, N` materializer,
resolved when `@A` is lowered). The registration carries the *binding*; the hash
*value* is filled at runtime per RFC 0004 §3.2's verification-on-registration.

## 2. Rewind-scope insertion

The uses of the consumed data are, by definition, built on an anchor a producer
rewind could void (RFC 0004 §3.3). Pass 2 encloses them in an
`hcp.rewind_scope { producer = @A }` so `agent-supervisord` knows exactly which
region cold-start verification (§6) must guard. Minimal form: one scope per
`(consumer, producer)` pair wrapping that producer's dependent uses; nested
consumes from distinct producers nest their scopes.

## 3. Pre/postconditions (the pass contract)

**Preconditions**
- Pass 1 ([0021](./0021-mlir-pass-topology-analysis.md)) succeeded — the graph
  is an acyclic, depth-bounded `state_dependency` DAG. (Injecting WAL into a
  cyclic graph is meaningless; Pass 1 gates Pass 2.)

**Postconditions**
- **No `vaked.consume` remains** — every one is lowered. (A surviving
  `vaked.consume` after Pass 2 is a pass bug.)
- Each injected sequence satisfies V-WAL-ORDER ([0020](./0020-mlir-hcp-dialect.md)
  §3.3): every `fetch_canonical_data` traces through a `write_ahead_log` to a
  `create_registration_token` for the **same** producer.
- The rewrite is **deterministic**: consumes lowered in module/op order; given
  the same input module, byte-identical output — the same purity contract as
  every `0012` emitter.

## 4. Stage-0 fidelity

Stage 0 does not yet emit `hcp` ops; it records the **same structural inputs**
from which the runtime performs the write-ahead. `vakedc/lower.py`
`emit_workflow_spec` writes `gen/workflow/<name>.json` with the dependency
`edges` (the `state_dependency` relation Pass 2 lowers) and the eventd `log`
path (the durable substrate the WAL writes to). In Stage 0 `agent-supervisord` +
`eventd` perform the registration at runtime from that wiring; Stage 1 makes the
`create → write_ahead → fetch` sequence explicit in IR. The Stage-1 pass MUST
preserve RFC 0004 §3.1 ordering and produce, per consume, exactly the binding
the Stage-0 spec's edge + log already imply
([0024](./0024-mlir-lowering-staged-adoption.md) §4) — no new dependency edge,
none dropped.

## Security considerations

- **Generated, never hand-authored.** Pass 2 is the mechanism that makes
  "hand-written registration is a conformance smell" (RFC 0004 §3.1) true: the
  only `hcp` WAL sequences in a compiled artifact are the ones Pass 2 emitted
  from a verified `vaked.consume`. A reviewer seeing a WAL sequence with no
  originating consume should treat it as tampering.
- **Completeness is the invariant.** The "no `vaked.consume` remains"
  postcondition is a security property: a consume that escaped lowering is a
  cross-agent read with **no** registration — precisely the unregistered
  consumption RFC 0004 §3 forbids.

## Open questions

- The `vaked.state_anchor` materializer (§1.1) is an internal device; whether it
  is a real op or a lowering-time symbol table entry is an implementation choice
  for the Stage-1 build (non-gating).
- Rewind-scope granularity (§2): one scope per `(consumer, producer)` vs one per
  consume site. Coarser scopes mean fewer cold-start re-verifications but wider
  pause blast radius; tune against RFC 0004 §6 verification cost.

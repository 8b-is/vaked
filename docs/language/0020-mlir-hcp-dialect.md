---
doc: 0020
title: "MLIR hcp dialect — write-ahead registration, fetch, rewind scope"
status: Accepted
track: Language / MLIR
created: 2026-06-14
issue: 23
epic: 17
---

# 0020 — The `hcp` MLIR dialect

Status: **Accepted** (2026-06-14) · Series: language design notes · Track:
**Language / MLIR** · Issue
[#23](https://github.com/peterlodri-sec/vaked-base/issues/23) · Epic
[#17](https://github.com/peterlodri-sec/vaked-base/issues/17)

Part of the MLIR set; umbrella + terminology in
[0013](./0013-mlir-topology-compilation.md). **Normative cross-reference:**
[RFC 0004 — Multi-Agent State Dependency](../../protocol/rfcs/0004-multi-agent-state-dependency.md)
§2 (frames), §3 (write-ahead discipline), §6 (cold start), §7 (epochs). The
durable substrate is `eventd`
([design](../superpowers/specs/2026-06-12-eventd-design.md)).

## Abstract

This part specifies the **low-level `hcp` dialect**: the MLIR modelling of the
protocol mechanics RFC 0004 defines. Pass 2
([0022](./0022-mlir-pass-wal-injection.md)) lowers each `vaked.consume`
([0019](./0019-mlir-vaked-dialect.md)) into an `hcp` sequence that builds a
`DependencyRegistration`, durably logs it write-ahead, then fetches the
producer's canonical output. The dialect's central design choice: **the
write-ahead invariant (RFC 0004 §3.1 — registration precedes consumption) is
encoded as an SSA def-use chain** (`token → receipt → data`), so no pass,
scheduler, or hand-edit can reorder the fetch before the log. Each op is mapped
to the exact RFC 0004 frame it realizes.

## Terminology

| Term | Definition | RFC 0004 |
|------|------------|----------|
| `DependencyRegistration` | Write-ahead control frame declaring a causal anchor before consumption. | §2, §3.1 |
| Registration token | The built-but-unlogged registration; SSA type `!hcp.reg_token`. | §2 |
| WAL receipt | Proof the registration was durably logged to `eventd`; SSA type `!hcp.wal_receipt`. **Carrying it as a value is the write-ahead invariant.** | §3.1 |
| Canonical data | The verified, fetched producer output; SSA type `!hcp.canonical_data`. | §3.2 |
| Rewind scope | A region whose anchors may be voided by a producer rewind; guarded by cold-start verification. | §3.3, §6 |
| Topology epoch | The graph version authorizing the edge; an `i64` attribute on the registration. | §7 |

## 1. Scope — what the `hcp` dialect does and does not lower

The dialect covers the **consume path**: the write-ahead registration, the
canonical fetch, and the rewind-vulnerable scope. It does **not** model the
runtime lifecycle frames, which are dynamic and owned by `agent-supervisord` /
`eventd`:

| RFC 0004 frame | In the `hcp` dialect? |
|----------------|-----------------------|
| `DependencyRegistration` (§2) | **Yes** — `hcp.create_registration_token` + `hcp.write_ahead_log`. |
| canonical fetch + verification (§3.2) | **Yes** — `hcp.fetch_canonical_data`. |
| `RewindEvent` / `stale_dependency` (§3.3, §6) | **Scope only** — `hcp.rewind_scope` marks the region; the event + pause are runtime. |
| `ConsumerCheckpoint`, GC floor (§4) | **No** — emitted at runtime *after* a fold; a dynamic checkpoint, not a compile-time structural edge. |
| `StaleDependency` record (§2) | **No** — a runtime pause reason, not a lowered op. |

Stating this boundary is load-bearing for coherence: an `hcp` op MUST correspond
to a frame RFC 0004 defines, and the runtime-only frames MUST NOT acquire `hcp`
ops. (See [0024](./0024-mlir-lowering-staged-adoption.md) §3, "what never enters
MLIR".)

## 2. Types

```
!hcp.reg_token        // a built DependencyRegistration, not yet logged
!hcp.wal_receipt      // proof of durable write-ahead log (eventd)
!hcp.canonical_data   // verified producer output, post-fetch
```

`!hcp.canonical_data` is what a `!vaked.state_hash` *use* becomes after Pass 2:
the consumed input, now backed by a verified fetch.

## 3. Operations

The sequence Pass 2 generates for one `vaked.consume` (RFC 0004 §3.1):

```mlir
%token   = hcp.create_registration_token {
             producer = @agent_alpha, producer_step = 15 : i64,
             topology_epoch = 7 : i64
           } %producer_hash : (!vaked.state_hash) -> !hcp.reg_token
%receipt = hcp.write_ahead_log %token  : (!hcp.reg_token)  -> !hcp.wal_receipt
%data    = hcp.fetch_canonical_data %receipt : (!hcp.wal_receipt) -> !hcp.canonical_data
```

### 3.1 `hcp.create_registration_token`

| | |
|---|---|
| **Role** | Build a `DependencyRegistration` frame (RFC 0004 §2) for one anchor. |
| **Operands** | `producer_step_hash : !vaked.state_hash` (the anchored hash, RFC 0004 `producer_step_hash`). |
| **Results** | `!hcp.reg_token`. |
| **Attributes** | `producer : FlatSymbolRefAttr` (→ a `vaked.agent`); `producer_step : i64`; `topology_epoch : i64` (RFC 0004 §7). `consumer` + `consumer_step` are taken from the enclosing `vaked.agent`/step context. |

Verifier — **V-REGTOK**: `producer` resolves to a `vaked.agent`; the operand is
`!vaked.state_hash`; the result is `!hcp.reg_token`; `topology_epoch` is present
(no anchor may be built without the epoch that authorized it — RFC 0004 §7).

### 3.2 `hcp.write_ahead_log`

| | |
|---|---|
| **Role** | Durably append the registration to `eventd` **before** any fetch (RFC 0004 §3.1). |
| **Operands** | `!hcp.reg_token`. |
| **Results** | `!hcp.wal_receipt` — the value carrying the write-ahead proof forward. |
| **Effects** | `MemoryEffects::Write` on the `eventd` resource (so it is never DCE'd or hoisted). |

Verifier — **V-WAL**: operand is `!hcp.reg_token`; result is `!hcp.wal_receipt`.

### 3.3 `hcp.fetch_canonical_data`

| | |
|---|---|
| **Role** | Verify the anchor against the producer's canonical chain (RFC 0004 §3.2) and fetch the output. |
| **Operands** | `!hcp.wal_receipt` — **the receipt operand is the write-ahead invariant**: the fetch data-depends on the log, so it can never be scheduled before it. |
| **Results** | `!hcp.canonical_data`. |
| **Effects** | `MemoryEffects::Read` on the `eventd` / producer resource. |

Verifier — **V-FETCH** (the structural write-ahead rule, RFC 0004 §3.1):
1. operand is `!hcp.wal_receipt`; result is `!hcp.canonical_data`;
2. the receipt's defining op is an `hcp.write_ahead_log` (directly or through
   pure forwarding), and *that* op's token comes from an
   `hcp.create_registration_token` for the **same** `producer`. A fetch whose
   receipt does not trace to a write-ahead log for its producer is ill-formed
   (**V-WAL-ORDER**) — this is the compile-time form of "registration precedes
   consumption."

### 3.4 `hcp.rewind_scope`

| | |
|---|---|
| **Role** | Encapsulate a block whose computation is built on anchors a producer rewind could void (RFC 0004 §3.3); marks the region `agent-supervisord` must guard with cold-start verification (§6). |
| **Attributes** | `producer : FlatSymbolRefAttr` (the upstream whose rewind threatens the scope). |
| **Regions** | exactly one, holding the dependent computation (typically the uses of an `hcp.fetch_canonical_data` result). |
| **Traits** | `SingleBlock`, region terminator `hcp.yield` (forwards the scope's results out). |

Verifier — **V-REWIND**: `producer` resolves to a `vaked.agent`; the region is
single-block and terminated by `hcp.yield`. The runtime contract: entering the
scope after a restart requires §6 verification to pass; a stale anchor pauses
the agent `stale_dependency` (a runtime state, not an op).

## 4. The write-ahead invariant as a def-use chain

RFC 0004 §3.1 requires registration to be durably logged *before* the consumer
reads the producer's output. Rather than rely on pass ordering or a comment,
the dialect makes it a **data dependency**:

```text
create_registration_token ──%token──▶ write_ahead_log ──%receipt──▶ fetch_canonical_data
        (build frame)                  (durable eventd)              (verify + read)
```

`fetch_canonical_data` consumes the `!hcp.wal_receipt` that only
`write_ahead_log` can produce, so any well-formed IR has logged before it
fetches — by construction, not by convention. V-WAL-ORDER rejects the
hand-written shortcut (a bare fetch, or a fetch wired to a forged receipt),
which is exactly the "hand-written registration is a conformance smell" rule of
RFC 0004 §3.1 expressed in the verifier.

## 5. TableGen mapping (Stage-1 starting point)

```tablegen
def Hcp_RegTokenType    : TypeDef<Hcp_Dialect, "RegToken">    { let mnemonic = "reg_token"; }
def Hcp_WalReceiptType  : TypeDef<Hcp_Dialect, "WalReceipt">  { let mnemonic = "wal_receipt"; }
def Hcp_CanonicalType   : TypeDef<Hcp_Dialect, "CanonicalData">{ let mnemonic = "canonical_data"; }

def Hcp_WriteAheadLogOp : Hcp_Op<"write_ahead_log", [MemoryEffects<[MemWrite]>]> {
  let arguments = (ins Hcp_RegTokenType:$token);
  let results   = (outs Hcp_WalReceiptType:$receipt);
}

def Hcp_FetchCanonicalDataOp : Hcp_Op<"fetch_canonical_data", [MemoryEffects<[MemRead]>]> {
  let arguments = (ins Hcp_WalReceiptType:$receipt);   // operand = write-ahead invariant
  let results   = (outs Hcp_CanonicalType:$data);
  let hasVerifier = 1;                                  // V-FETCH / V-WAL-ORDER
}
```

## Security considerations

- **The receipt operand is a security control, not ergonomics.** If a future
  revision lets `hcp.fetch_canonical_data` take the producer directly (dropping
  the `!hcp.wal_receipt`), it silently re-permits consumption without
  registration — the exact integrity hole RFC 0004 §3 closes. V-WAL-ORDER MUST
  remain.
- **Epoch is mandatory at token build (V-REGTOK).** A registration without its
  authorizing `topology_epoch` cannot be audited (RFC 0004 §7); the verifier
  rejects it rather than defaulting the epoch.
- **The dialect lowers no checkpoint/GC op.** Keeping `ConsumerCheckpoint` and
  GC-floor logic out of MLIR (§1) means the compaction-safety decision stays in
  the runtime where the live lease/eviction state is (RFC 0004 §4) — the
  compiler must not appear to authorize compaction it cannot observe.

## Open questions

- Should `hcp.rewind_scope` carry the anchored `producer_step` so the verifier
  can cross-check it against the enclosing `hcp.create_registration_token`, or
  is the runtime §6 check sufficient? (Non-gating for v1.)
- Whether `!hcp.canonical_data` should be the same type as `!vaked.state_hash`
  (unifying the dataflow token across dialects) or stay distinct to mark the
  "verified + fetched" transition. Distinct is clearer for Pass 2's rewrite.

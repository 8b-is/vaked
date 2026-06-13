# 0016 — Substrate & distribution candidates (triage)

Status: **reference / triage** (2026-06-12) · Series: language design notes ·
Issues [#50](https://github.com/peterlodri-sec/vaked-base/issues/50)
[#51](https://github.com/peterlodri-sec/vaked-base/issues/51)
[#52](https://github.com/peterlodri-sec/vaked-base/issues/52)

## Spark

A second owner technology dump (the first became
[0013](./0013-mlir-topology-compilation.md)): fourteen substrate, build, and
distribution rows (SPIFFE/SPIRE and NATS are one candidate sharing #52;
distroless OCI rides #50) for the agentfield runtime. As with 0013, the value is
in the **anchoring** — several of these name things the architecture already
has, and saying so prevents parallel inventions. Verdicts: **slot** (a design
issue is open), **reference** (recorded here + the
[reference map](./0003-reference-map.md); revisit at its named trigger), or
**have-it** (exists under another name — do not rebuild).

## Triage

| Candidate | Anchor in this repo | Verdict |
|-----------|--------------------|---------|
| **Wasmtime / Component Model** | worker isolation with instant linear-memory snapshots (↔ arena checkpoints #16, eventd phase 4) and instruction-metered budgets (↔ `budget` #28, enforced mathematically rather than by broker policy); a third worker backend after BEAM port and Zig daemon | **slot → #50** — designed: [wasm worker isolation](../superpowers/specs/2026-06-13-wasm-worker-isolation-design.md) (sandboxd backend, `budget.fuel` metering, raw→arena snapshots) |
| **NixOps / Colmena** | the direct consumer of the `host` schema's `deploy` field (#28 slice 3): one declarative `colmena apply` over the emitted `nixosModules` for the whole multi-runtime topology | **slot → #51** (the nearest-term row) |
| **SPIFFE/SPIRE** | transport-layer identity: `DependencyRegistration` frames validated by mTLS *before parsing*; candidate canonical AgentId for RFC 0005's name→AgentId roster question | **slot → #52** — designed: [RFC 0006](../../protocol/rfcs/0006-transport-identity-distribution.md) |
| **NATS** | `agent.*.rewind` wildcard fan-out for cross-node `RewindEvent` distribution; KV/object store as retained-accumulator transport (RFC 0004 §4). Boundary: notifications and proofs only — the hash-chained log stays the single source of truth | **slot → #52** — designed: [RFC 0006](../../protocol/rfcs/0006-transport-identity-distribution.md) §2 |
| **Temporal / effect systems** | **have-it**: durable execution = the eventd fold + the supervisord `workflow_engine` — "virtual threads sleeping for days" and crash-resume follow from state-is-a-fold plus the engine's logged step events (an inference from the designs, not yet a stated requirement in them) | have-it |
| **Determ-SR** | **have-it**: deterministic state recovery = the content-addressed Nix store (environments) + RFC 0004 §6 cold-start verification (state) — the two layers this names are both specified | have-it |
| **crane / dream2nix** | granular per-component Nix caching when `gen/` artifacts become *built* (Zig daemons, WASM components): changing one agent's skill rebuilds one derivation, not the cluster | reference; trigger = first compiled-agent build (#15-era) |
| **Content-Addressed Nix** | CA derivations mirror immutable increments: identical MLIR/lowering output ⇒ identical store path ⇒ fleet-wide no-op deploy. Experimental Nix feature | reference; trigger = #51 deploy loop maturing |
| **TVM / Relay** | below the 0013 stack: AOT-compile local model-inference tools to hardware-specific code inside the Nix build | reference; trigger = first local-inference fiber |
| **Linear / affine types** | use-exactly-once / at-most-once resources in the 0011 type system — natural fit for one-shot capability grants and consumed artifacts | reference; trigger = 0011 revision |
| **Polyhedral compilation** | scheduling cascading-rewind recovery (A→B→C) for memory locality inside MLIR | reference; trigger = 0013 Stage 1 |
| **CCN / NDN** | anchors as *content names* (`/agent_alpha/step_15/<hash>`): a rewind invalidates the name in the network fabric itself — RFC 0004's invariants pushed into routing | reference; trigger = #52 outgrowing point-to-point |
| **Distroless Nix OCI** | immutable, shell-less, <50MB images for the `container` kind's lowering | reference (bundled in #50 as the conservative isolation path) |
| **ZKP / RISC Zero** | zk-STARK alongside a `RewindEvent`: "my new tip is un-drifted" provable across org boundaries without exposing logs — extends RFC 0004 §4 proof retention beyond trusting the chain holder | reference; trigger = first cross-boundary consumer |

## The pattern worth stating once

Every "verdict: have-it" above resolves to the same two foundations — the
hash-chained log (state is a fold; eventd design + RFC 0004) and content addressing
(environments and graph nodes; Nix store + arena). Candidates should be
evaluated by what they add *on top of* those two, never as replacements:
Wasmtime adds a snapshotable compute substrate, NATS adds fan-out, SPIFFE adds
transport identity, ZKP adds third-party verifiability. Anything that proposes
a second source of truth is automatically wrong here.

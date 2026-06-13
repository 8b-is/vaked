# Related Work: Vaked's Position in the Landscape

## Overview

Vaked synthesizes ideas from several research communities:

1. **Configuration languages with structural typing and contracts** (Nickel, CUE, Dhall)
2. **Policy and authorization systems** (OPA/Rego, SPIFFE/SPIRE, object capabilities)
3. **Multi-target code generation** (MLIR, TVM)
4. **Deterministic, reproducible systems** (Nix, flakes)

This document positions Vaked's contributions relative to existing work.

---

## Configuration Languages: Structural Typing & Constraints

### Nickel

**Scope:** Structural records with contract system (refinement types).

**Relationship:**
- **Borrowed:** Structural record typing (no nominal types; value shape determines type)
- **Borrowed:** Contract/refinement idea (field constraints checked at conformance time)
- **Divergence:** 
  - Nickel allows **open predicates** (`|nickel_code| -> bool`), enabling Turing-complete checking but risking non-termination and side effects. Vaked **closes the constraint set** (§3 of 0011): only built-in refinements (`in`, `oneof`, `matches`, bounds, `required`/`optional`/`default`). This guarantees **decidability and totality**.
  - Nickel is an **expression language** (supports general computation, imports, function application). Vaked is a **declaration language** (schemas and graphs, pure data).
  - Vaked adds **capability attenuation ordering** as a first-class typing concept (domains, grant sets, POLA); Nickel has no notion of authority flow.

### CUE

**Scope:** Schema and constraint language for configuration; structural typing with unification.

**Relationship:**
- **Borrowed:** Structural field constraints (range checks, `oneof`, regex matching)
- **Borrowed:** Schema validation as a central operation
- **Divergence:**
  - CUE supports **general unification**, including cyclic definitions and constraint solving. Vaked uses **local, structural checking only** — no backtracking search, no fixpoint. This trades expressiveness for guaranteed termination.
  - CUE permits **user-defined validators** (custom logic in Cue code). Vaked **forbids this by design** to preserve decidability.
  - Vaked's **capability domains and attenuation orders** are not present in CUE; CUE treats authority constraints like any other field constraint.

### Dhall

**Scope:** Total, side-effect-free, strongly typed configuration language.

**Relationship:**
- **Borrowed:** Core principle of **totality** — all evaluation terminates; no side effects (network, files)
- **Borrowed:** No Turing-complete embedded computation; configuration is data, not code
- **Divergence:**
  - Dhall uses **dependent types** (types can depend on values); Vaked uses **structural typing without dependent types** (simpler, still total)
  - Dhall's **import mechanism** (even with semantic integrity checks) introduces a distribution/trust model; Vaked outsources trust to Nix's `flake.lock` pinning
  - Vaked adds **capability topology** (graphs, meshes, delegation rules); Dhall treats all fields uniformly.

### Key Distinction: Closed Constraint Sets

The critical choice in Vaked's design is **forbidding user-defined predicates** (§3.6 of 0011, and "Why closed"). This differs from Nickel, CUE, and even Rego, which permit arbitrary custom logic. 

**Tradeoff:**
- **Gain:** Decidability, termination, and side-effect freedom. Checking is O(|schema| × |record|) and always finishes.
- **Cost:** Some real-world validation needs (e.g., "field A must be even" or cross-field dependencies) cannot be expressed. These surface as **language design events** (§6.2 of 0011): the language is extended, not the validator.

---

## Authorization & Capability Systems

### Object Capabilities (Mark Miller, Alan Karp, et al.)

**Scope:** Foundation for secure distributed systems via unforgeable references.

**Relationship:**
- **Borrowed:** Core principle: **Principle of Least Privilege (POLA)** — no principal should hold more authority than necessary to perform its role
- **Borrowed:** Authority as a **partial order** (some grants are weaker/stronger than others)
- **Borrowed:** **Attenuation** as the mechanism for reducing authority along delegation
- **Implementation detail:** Traditional object capabilities rely on runtime membranes and unforgeable object references. Vaked moves the enforcement to **static type-checking** (§4 of 0011): the type system certifies authority flow is monotone-decreasing before any code runs. This is a **compile-time proof** of POLA compliance, not a runtime enforcement mechanism.

### SPIFFE/SPIRE

**Scope:** Runtime identity and authorization for distributed workloads (mutual TLS, SVID).

**Relationship:**
- **Borrowed:** **Capability-based transport** — cryptographic proof that a principal holds a specific authority (SVID is a signed, time-bound credential)
- **Parallel, not competitor:** 
  - SPIFFE/SPIRE operates at runtime, issuing and verifying credentials during message exchange
  - Vaked operates at declaration-time, declaring upfront which principals may hold which capabilities
  - Together: Vaked could **compile to SPIFFE workload descriptors** (an emitter target), and the runtime could **use SPIRE to enforce** the authority graph at the protocol layer
- **Divergence:**
  - SPIFFE treats identity as primary; Vaked treats authority (capability) as primary
  - SPIRE is a trust authority that signs and issues credentials; Vaked has no runtime authority (all decisions are static)

### OPA/Rego

**Scope:** Policy-as-code engine: declare authorization rules in a logic-programming language.

**Relationship:**
- **Borrowed:** Idea of **declaring security policy separately from business logic**
- **Borrowed:** Input-to-policy-decision pipeline (graph → policy engine → yes/no)
- **Divergence:**
  - OPA uses a **logic-programming language** (Rego, closer to Prolog) with rule matching and backtracking. This is Turing-complete and may not terminate on malformed input. Vaked uses **closed constraints** (not Turing-complete) for guaranteed termination.
  - OPA evaluates policy at **runtime** (request comes in → Rego rules evaluated → decision). Vaked certifies policy compliance at **compile time** (graph is checked once).
  - Vaked is **not** a policy *engine* in the OPA sense; it is a **language** where authority constraints are built into the type system.

---

## Multi-Target Code Generation

### MLIR (Multi-Level Intermediate Representation)

**Scope:** Compiler infrastructure for lowering programs through dialect layers to machine code.

**Relationship:**
- **Borrowed:** Idea of **multi-level lowering** — a program is progressively lowered through increasingly concrete representations
- **Borrowed:** **Dialect-specific rules** for how higher-level constructs map to lower-level artifacts
- **Divergence:**
  - MLIR targets **machine code** (CPU instruction generation); Vaked targets **text artifacts** (Nix, Zig configs, JSON, CrabCC indexes, OTel YAML)
  - MLIR supports arbitrary lowering rules (often data-dependent); Vaked's lowering is **pure, deterministic graph-to-text rendering** (§1–2 of 0012) with no conditional branching based on runtime values
  - MLIR is **closed-world within the compiler**; Vaked explicitly separates the compiler from the build (`flake.nix` and Nix handle fetching/building)

### TVM (Tensor Virtual Machine)

**Scope:** Compiler framework for deploying ML models across diverse hardware targets.

**Relationship:**
- **Parallel goal:** Compile one high-level declaration to multiple backend targets (CPUs, GPUs, specialized hardware)
- **Divergence:**
  - TVM focuses on **performance optimization** across backends; Vaked focuses on **authority and reproducibility** across infra artifacts
  - TVM's lowering includes **auto-tuning and scheduling**; Vaked's lowering is **deterministic** (byte-identical output for identical input)

---

## Reproducibility & Determinism

### Nix & Flakes

**Scope:** Declarative package and configuration management with reproducible builds.

**Relationship:**
- **Borrowed:** **Deterministic evaluation** — pure functions, no I/O, pinned sources
- **Borrowed:** **Flakes** as a pinning mechanism (all dependencies locked in `flake.lock`)
- **Borrowed:** Idea that **artifacts are traceable to their sources** (content-addressed, input-hashed)
- **Role in Vaked's architecture:** Nix is the **"materialization" layer** (per 0001's mantra). Vaked declares the *what*; `flake.nix` and `nix build` do the *how* (fetch, compile, deploy).
- **Divergence:**
  - Nix is a **lazy evaluation language** with thunks and implicit memoization. Vaked has **no evaluation** — it is pure structural data + schema checking.
  - Nix's **derivations** are the unit of reproducibility (defined by `name`, `builder`, `inputs`). Vaked's **provenance** (§6.2 of 0012) maps artifact regions back to source spans, enabling **auditable tracing**.

---

## Capability Graphs & Authority Topology

Vaked's synthesis of structured types, capability ordering, and multi-target lowering is not replicated in existing work. The closest parallels are:

1. **Capability-safe languages** (E, Joe-E, Emily) which encode POLA in a type system, but do not target infrastructure-as-code or multi-tenant systems.
2. **Authorization logic languages** (SecPAL, Cassandra) which formalize delegation, but require runtime evaluation.
3. **Policy languages** (Kubernetes RBAC, AWS IAM) which express authority matrices but do not have formal type-theoretic foundations.

Vaked's contribution is **marrying typed capability attenuation (from object-capability literature) with deterministic code generation (from Nix/reproducibility systems) to enable statically-verified, auditable infrastructure declarations**.

---

## Positioning Summary

| System | Structural Types | Constraints | Capabilities | Multi-Target | Deterministic | Runtime vs. Compile-Time |
|--------|------------------|-------------|--------------|--------------|--------------|--------------------------|
| **Nickel** | ✓ (open constraints) | ✓ (open predicates) | — | — | ✗ (side effects) | Runtime |
| **CUE** | ✓ (unification) | ✓ (custom validators) | — | — | ✓ (local) | Runtime |
| **Dhall** | ✓ (dependent) | — | — | — | ✓ (total) | Compile-time |
| **OPA/Rego** | — | ✓ (logic program) | ✓ (implicit) | — | ✗ (may not terminate) | Runtime |
| **SPIFFE/SPIRE** | — | — | ✓ (SVID) | — | ✓ (static creds) | Runtime |
| **MLIR** | — | — | — | ✓ (many targets) | ✓ (machine code) | Compile-time |
| **Nix** | — | — | — | ✓ (one target) | ✓ (pure evaluation) | Compile-time |
| **Vaked** | ✓ (closed) | ✓ (closed set) | ✓ (POLA) | ✓ (text artifacts) | ✓ (pure + total) | Compile-time |

**Vaked's unique position:** Closed structural types + closed constraints + typed POLA + deterministic multi-target code generation, all at compile-time.

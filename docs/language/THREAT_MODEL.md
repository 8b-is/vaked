# Threat Model: Vaked POLA Guarantees and Boundaries

## Overview

Vaked's security model is built on **Principle of Least Privilege (POLA)**: no principal should exercise more authority than necessary for its role. This document defines:

1. What Vaked **guarantees** (static, compile-time)
2. What Vaked **does not guarantee** (runtime enforcement is out-of-scope)
3. How to interpret Vaked's security claims in an integrated system

---

## Part 1: The POLA Guarantee

### 1.1 Formal Statement

**Vaked's POLA invariant (informal):** If a Vaked declaration passes type-checking (Goal 2, §6 of 0011), then:

> **No principal can exercise a capability strictly above (in the attenuation order) any capability held in any of its granted sets.**

More precisely (§4.5 of 0011):

1. Let `p` be a principal (node, fiber, surface, etc.) in the graph.
2. Let `granted(p)` be the set of capabilities written in `capabilities = [...]` on `p`.
3. Let `used(p)` be the set of capabilities that `p`'s engines, streams, effects, and connected services *require*.
4. Let `G` be the set of all capabilities held by any upstream delegator of `p` (in a mesh or routing topology).
5. **Claim:** For all `c ∈ used(p)`, there exists `g ∈ granted(p)` such that `c ≤ g` (in the attenuation order). Additionally, every grant held by `p` is `≤` every grant held by upstream delegators (monotone attenuation along edges).

If both conditions hold, the type system certifies that **authority only flows downward (or stays equal) along delegation paths**, and **no principal exercises authority it was not granted**.

### 1.2 Informal Soundness Sketch

The type checker enforces this via three rules (§4 of 0011):

**Rule 1: Use Check (Local)**
For every principal `p`:
```
used(p) ⊑ granted(p)
```
where `c ⊑ G` means "there exists `g ∈ G` in the same domain with `c ≤ g`."

*Intuition:* A principal cannot exercise a capability unless it was granted something at least as strong.

**Rule 2: Attenuation Check (Delegation)**
For every delegating edge `s -> r` (sender to receiver):
```
granted(r) ⊑ granted(s)
```

*Intuition:* A receiver cannot be granted more authority than the sender holds. Authority is attenuated (decreases or stays equal) along delegation edges.

**Rule 3: Partial Order Validity**
For each capability domain, the attenuation order `<` must form a **partial order** (reflexive, transitive, antisymmetric). This is checked at schema load (§4.2 of 0011).

*Why this ensures POLA:*
- By Rule 3, `≤` is well-defined (transitive closure of `<`).
- By Rule 1, any capability `p` exercises is covered by a grant it holds.
- By Rule 2, along any path `s ->* r`, `granted(r) ⊑ granted(s)`.
- By transitivity of `⊑`, any grant `r` holds is `≤` a grant any upstream delegator holds.
- Combining: any capability `p` exercises is `≤` a grant it holds, which is `≤` a grant any ancestor holds. Thus authority is bounded by the root grant and never increases.

### 1.3 Scope of the Guarantee

**Vaked guarantees:**
- ✅ No principal's **declared capabilities** exceed the declared authorities of its delegators
- ✅ No principal **attempts to use** (in its declared engines/streams/effects) a capability stronger than what it was granted
- ✅ Authority does not **increase** along delegation paths
- ✅ The **static authority topology** (who holds what) is consistent with POLA before any code runs

**Vaked does NOT guarantee:**
- ❌ Runtime enforcement: The Zig daemons, eBPF layer, and OTP supervisor must actually enforce the authority graph. Vaked cannot prevent a buggy or compromised runtime daemon from violating the declared capability boundary.
- ❌ Secrets/cryptographic enforcement: Vaked does not emit cryptographic proofs or credentials; it emits *text* (configs, JSON, Nix). The runtime must translate the declared authority into cryptographic or syscall-level checks.
- ❌ Revocation: Vaked specifies authority *statically*. Revoking a capability (e.g., a fiber loses access mid-execution) is a **runtime membrane** operation, not a Vaked operation.
- ❌ Timing/side-channel attacks: Vaked does not model timing, signal handling, or covert channels.
- ❌ Compromise of authorities: If a principal that holds root authority is compromised, POLA cannot help. The threat model assumes authorities (domains, grants, the root grant-set) are themselves trustworthy.

---

## Part 2: Attack Scenarios

### Scenario A: Privilege Escalation via Type Evasion

**Attack:** A fiber declares `capabilities = [fs.repo_rw]` but references an engine that actually requires `fs.repo_rw_dangerous`.

**Reality check:** The type system (Rule 1, Use Check) compares the engine's schema-declared requirements against the fiber's granted set. If the engine's schema says it needs `fs.repo_rw_dangerous`, and the fiber only holds `fs.repo_rw`, the check fails with a capability-use error.

**Defense:** The **schema** for each engine/stream declares its capability requirements. These are **not user-provided**; they are part of the language specification (in `parallel-types.md`). If a real engine has a capability requirement that the schema doesn't model, that is a **language design event** (§6.2 of 0011): the schema is fixed, not the application.

### Scenario B: Capability Amplification via Delegation

**Attack:** A delegator `A` holds `fs.repo_ro` but delegates to `B` a grant `fs.repo_rw`.

**Reality check:** The type system (Rule 2, Attenuation Check) verifies that `granted(B) ⊑ granted(A)`. Since `fs.repo_rw > fs.repo_ro` (repo_rw is stronger), the delegation violates the attenuation order. The checker rejects it.

**Defense:** Type-checking at declaration time, before any code runs.

### Scenario C: Undeclared Capability Use via Code Injection

**Attack:** An attacker injects code into a Vaked engine/stream such that it uses capabilities not declared in its schema.

**Reality check:** Vaked does **not prevent this**. This is a **runtime attack**, outside the scope of the type system. The defense is:
1. **Daemon sandboxing** — Zig daemons should run in OS-level sandboxes (seccomp, pledge, pledge-like mechanisms).
2. **eBPF policy enforcement** — Syscall interception and audit.
3. **Capability revocation** — If a daemon is compromised, the OTP supervisor can revoke its membranes.

These are **runtime enforcement** mechanisms, not Vaked's job. See §Scope.

### Scenario D: Privilege Escalation via Mesh Cycles

**Attack:** Create a cycle in a mesh: `A -> B -> C -> A`. Can authority increase around the loop?

**Reality check:** The type system allows cycles structurally (they represent feedback or bidirectional communication). However, the attenuation check (Rule 2) still applies: `granted(B) ⊑ granted(A)`, `granted(C) ⊑ granted(B)`, `granted(A) ⊑ granted(C)`. This forces `granted(A) ⊑ granted(B) ⊑ granted(C) ⊑ granted(A)`, which by antisymmetry means all three have **identical grant-sets**. The cycle forces equality, which is sound (no escalation, just symmetric authority).

**Defense:** Type-checking + partial-order properties.

### Scenario E: Authority Hiding via Schema Omission

**Attack:** Declare a `runtime` with an engine, but omit the `capabilities` field. Does it default to empty (no authority)?

**Reality check:** From §1.2 of 0011, a field with `default = [...]` is elaborated at type-check time. If the schema for `runtime` marks the `capabilities` field as `optional`, an omission is legal and elaborated to `[]` (empty grant-set). A field marked `required` with no `default` is a schema error if omitted.

The language design (the schema for `runtime`) determines whether capabilities are mandatory or optional. If a real system *requires* an explicit authority declaration, the schema must mark it `required`.

**Defense:** Schema-level enforcement. The language design team (not application authors) decides this.

---

## Part 3: Integration with Runtime Layers

### The Division of Responsibility

Vaked operates in a **three-layer architecture** (per the manifesto: *"Vaked declares. Nix materializes. Zig enforces. eBPF testifies."*):

| Layer | Component | Responsibility |
|-------|-----------|-----------------|
| **Declaration** | Vaked | Declare authority topology; type-check POLA consistency |
| **Build & Pin** | Nix + `flake.lock` | Fetch, build, and pin all dependencies; ensure artifact reproducibility |
| **Runtime** | Zig daemons + OTP | Execute principals; enforce authority membranes; manage revocation |
| **Audit** | eBPF + CrabCC | Intercept syscalls; verify authority at enforcement boundary; index call sites |

### What the Zig/eBPF Layer Must Do

For Vaked's POLA guarantee to be **end-to-end**, the runtime must:

1. **Create membranes:** Each principal (fiber, node) runs in a distinct security context (process, namespace, container).
2. **Enforce capability checks:** Before a principal exercises a capability (e.g., opens a file, makes a network call), verify it holds the corresponding grant (or a stronger one).
3. **Implement attenuation:** When a principal delegates to another (via message passing, RPC, etc.), the receiver's effective grant-set is the **intersection** of what was granted and what the receiver declared.
4. **Prevent revocation escape:** If the OTP supervisor revokes a capability, the principal loses the ability to exercise it (via membrane revocation, not just configuration change).

### What the Nix Layer Must Do

Nix ensures **supply-chain reproducibility**:

1. **Pin all sources:** `flake.lock` records the exact commit/hash of every dependency (Zig stdlib, engine code, secrets, etc.).
2. **Reproducible builds:** Derive artifacts from the pinned sources deterministically (no timestamps, no random data, no network).
3. **Audit trail:** The built artifacts' provenances (from `provenance.json`, see §6.2 of 0012) trace back to Vaked declarations and Nix derivations, forming an **auditable chain**.

---

## Part 4: What Could Still Go Wrong?

Even with Vaked POLA + Nix reproducibility + Zig enforcement, the system can be compromised by:

### 4.1 Bugs in the Vaked Type Checker
If the checker has a bug (e.g., incorrectly accepting an attenuation violation), the POLA invariant is not statically verified. **Mitigation:** Spec tests (§ of 0011) and differential oracle testing against the spec.

### 4.2 Bugs in Zig Daemons
A daemon might have a memory safety bug (buffer overflow, use-after-free) exploited to escape the sandbox. **Mitigation:** Zig's memory safety guarantees (manual but checked) + eBPF as a defense-in-depth boundary.

### 4.3 Privilege-Escalation in Kernel / Hypervisor
If the host OS or hypervisor has a privilege escalation vulnerability, POLA cannot help. **Mitigation:** Regular patching, exploit mitigations (ASLR, CFI, etc.) at the OS level.

### 4.4 Compromise of the Root Authority
If the principal holding the root capability (e.g., the "admin" fiber with `fs.repo_rw` and `network.full`) is compromised, all delegated principals are at risk. **Mitigation:** Principle of least privilege applies to the root authority itself; minimize who/what holds ultimate authority.

### 4.5 Supply-Chain Attacks on Dependencies
An attacker compromises a Zig library that a daemon links. **Mitigation:** Nix's `flake.lock` pinning + reproducible builds enable verification (rebuild and checksum); still relies on the integrity of the pinned sources.

---

## Part 5: Summary for Paper / Evaluation

### Vaked's Security Claims (for publication)

1. **Static POLA Verification:** Vaked's type system certifies that authority topology is POLA-consistent before compilation. This is a *compile-time* proof, not a runtime check.

2. **Decidable Checking:** The constraint set is closed, making conformance and capability-flow checking decidable and terminating (no halting-problem edge cases).

3. **Provenance Tracking:** Every artifact carries a provenance map (§6.2 of 0012) linking artifact regions to source spans, enabling auditable tracing from infra back to declarations.

4. **Deterministic Lowering:** The same Vaked declaration produces byte-identical artifacts (given the same inputs/pinned sources), enabling reproducibility checks.

### Threat Model Scope

| Threat | Vaked Scope | Out of Scope |
|--------|------------|--------------|
| **Static POLA verification** | ✅ | — |
| **Runtime authority enforcement** | Advisory (design guidance) | ✅ Zig/eBPF |
| **Secrets management** | ❌ (no embedded secrets) | ✅ Nix/agent integrations |
| **Compromise of root authority** | ❌ (policy question) | — |
| **Kernel/OS exploits** | ❌ | ✅ OS hardening |
| **Supply-chain attacks on pinned sources** | ⚠️ (detectable via reproducibility) | ✅ Nix/GPG verification |
| **Timing/covert channels** | ❌ | — |
| **Revocation enforcement** | Advisory (membranes) | ✅ OTP supervisor |

### Evaluation Plan

For the paper, evaluate:
1. **Type-checker correctness:** Specification tests + differential oracle (compare vakedc output to hand-written expected outputs).
2. **POLA soundness:** Case studies showing how violations are caught at type-check time.
3. **Performance:** Compile time, type-check time, artifact size vs. codebase complexity.
4. **Practical examples:** Demonstrate POLA enforcement on 2–3 real-world agentic workloads (operator-field, agentfield-swe, memory/workflow).

---

## References

- Miller, M., Tulloh, B., et al. "Capability-Based Financial Instruments." *International Conference on Financial Cryptography and Data Security*, 2000.
- Karp, A. H. "A Language for Distributed Applications." *ACM SIGPLAN Notices*, 1994.
- Neumann, P. G. "Computer-Related Risks." *ACM Press*, 1995.
- Saltzer, J. H., and Schroeder, M. D. "The Protection of Information in Computer Systems." *Proceedings of the IEEE*, 1975.

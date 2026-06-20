# Publication review - 0024 MLIR lowering contract and staged adoption

Status: **Editorial artifact** (review companion; does not mutate the spec) | Created: 2026-06-14 | Track: Language / MLIR
Target: [`0024-mlir-lowering-staged-adoption.md`](../0024-mlir-lowering-staged-adoption.md) · Umbrella: [`0013`](../0013-mlir-topology-compilation.md) · Issue [#23](https://github.com/peterlodri-sec/vaked-base/issues/23) · Epic [#17](https://github.com/peterlodri-sec/vaked-base/issues/17)

This artifact is the output of the V1.0 publication pipeline applied to 0024. It is intentionally non-destructive: it audits the existing spec, anchors its claims, and proposes a publication-ready rewrite of the load-bearing sections (§2). Folding the rewrite into 0024 itself is a separate, gated step (design -> plan -> implement).

---

## 1. Section diagnosis

**Thesis (extracted, current):** "Stage-1 MLIR lowering must faithfully reproduce Stage-0 LPG pass behavior; the Stage-0 implementation is the oracle."

**Thesis (sharpened, proposed):** *Stage-1 is a translation-validated reimplementation of the Stage-0 LPG pipeline in MLIR: it must be **observationally equivalent** to Stage-0 on the compiler-artifact set (topology, WAL sequences, supervisor index), verified by differential round-trip testing, with the executable Stage-0 passes as the reference oracle.*

What is strong:
- Clear Stage-0/Stage-1 boundary; the "what never enters MLIR" table (§3.1) is precise and well-authored.
- The oracle principle (§4.1) is the right call and is stated cleanly.
- Verification *approaches* (§2.2, §7.3) already describe differential testing - the rigor is present in the procedure but not in the vocabulary.

What weakens it for publication:
1. **Vocabulary gap.** The document reinvents three named, well-established concepts without naming them: *translation validation* (§2.1, §4.1), *reproducible build* (§2.2), and *MLIR ODS/TableGen verifiers* (§2.3). A reviewer from the compiler community will expect the terms.
2. **One overclaim.** "Semantically equivalent" (§2.1, §9.2) is stronger than what the method delivers. Differential testing establishes *observational* equivalence on a finite, chosen artifact set - not general semantic equivalence (which is undecidable in the limit and, where tractable, requires bounded SMT translation validation à la Alive2 or a Coq proof à la CompCert). Downgrade the word or upgrade the method.
3. **One self-contradiction.** "byte-identical artifacts (modulo timestamps and random tokens)" (§2.2) - "byte-identical *modulo* X" is not byte-identical. The field's term for what is meant is *reproducible after canonicalization*: strip non-deterministic inputs, then compare bit-for-bit.
4. **Zero external anchors.** The MLIR dialect/verifier/lowering machinery is assumed (SSA, ODS, ConversionTarget) with no citation. Acceptable for an internal draft; insufficient for a publication-grade artifact.
5. **No empirical claims, and that is correct** - but the "O(1) subscription lookup" / "flat-array read" claim (inherited from 0013 terminology and 0023) is asserted, not shown. It is true *only if* agent IDs are dense integers indexing a packed array; §5 establishes sequential IDs, which makes it true, but the artifact should connect those two facts explicitly.

**Status recommendation:** 0024 is currently `Review` and marked *optional* for implementation-gating in 0013. With the §2 rewrite below it is publication-grade and can stand at `Accepted`. The gating docs 0019-0023 carry the implementable precision; 0024 carries the contract, so `Accepted` here is a framing-quality bar, not an implementation bar.

---

## 2. Claim audit table

Classification key: **PUB** public-source-backed · **INT** internal-design-backed · **SPEC** speculative / benchmark-required · **RW** remove-or-rewrite.

| # | Claim (loc) | Class | Source anchor / action |
|---|-------------|-------|------------------------|
| C1 | Stage-1 must preserve Stage-0 semantics; differ -> Stage-0 wins (§2.1, §4.1) | INT + PUB | Internal oracle decision; the *technique* is **translation validation** (Pnueli 1998; Alive2 PLDI'21). Anchor the term. |
| C2 | "Semantically equivalent" artifacts (§2.1, §9.2) | RW | Overclaim. Rewrite to **observational equivalence on the artifact set, by differential round-trip testing**. Full semantic equivalence is bounded (Alive2) or proof-heavy (CompCert). |
| C3 | "byte-identical artifacts (modulo timestamps and random tokens)" (§2.2) | RW | Self-contradictory. Rewrite as **reproducible build**: canonicalize (strip timestamps/tokens, sort arrays), then bit-for-bit compare. Anchor reproducible-builds.org definition. |
| C4 | Normalize -> hash -> hashes must match (§2.2) | PUB | Canonical reproducible-build verification. Correct; keep, anchor. |
| C5 | Stage-1 dialect verifiers enforce same invariants as Stage-0 checker (§2.3) | INT + PUB | Realizable via MLIR **ODS/TableGen** declarative verifiers (mlir.llvm.org ODS). Anchor that this is a supported MLIR mechanism, not a bespoke invention. |
| C6 | `vaked`/`hcp` dialects are "TableGen-ready" (0013 §, inherited) | PUB | Confirmed: ODS `.td` records generate op classes + verifiers. Anchor. |
| C7 | Excluded subsystems stay in runtime (§3.1 table) | INT | Internal design decision; well-cited internally (0014, DEPLOY.md, RFC 0004). Keep as-is - exemplary. |
| C8 | Stage-0 passes are the oracle (§4.1) | INT | Internal decision; sound. Frame as translation-validation *reference semantics*. |
| C9 | Agent IDs sequential in source order, stable, no hashing (§5) | INT | Internal; this is the *precondition* that makes C11 (O(1)) true. Cross-link explicitly. |
| C10 | depth(A)=0 if source else 1+max(producers); critical path = max depth (§6.1) | PUB | Standard DAG longest-path / topological-sort DP. Anchor as classical; keep. |
| C11 | "O(1) runtime subscription lookups / flat-array read" (0013, 0023) | INT (needs link) | True *iff* IDs are dense integers (C9). Not benchmarked, but does not need a benchmark - it is a data-structure property. State the precondition; do not call it a performance result. |
| C12 | WAL sequence register -> log -> fetch, fixed order, no intervening ops (§7) | INT | Internal; bound to RFC 0004 §2-§3. Keep, cross-link. |
| C13 | `hcp` ops correctly implement RFC 0004; discrepancy = spec bug (§13.3) | INT | Internal coherence requirement. Keep. |
| C14 | Round-trip equivalence on a "diverse test suite" (§2.2, §11) | SPEC | The suite does not yet exist. This is the **one genuine evidence gap** - see §4. |

Tally: PUB 4 · INT 7 · RW 2 (C2, C3) · SPEC 1 (C14) · INT-needs-link 1 (C11). No claim requires removal; two require rewrite; one requires a (testing) artifact before it can be checked off.

---

## 3. Enrichment opportunities

- **Name the discipline.** Add one sentence to the Abstract: "This is a *translation validation* contract: Stage-1 is validated against Stage-0 as the reference, in the sense of Pnueli et al. and the LLVM Alive2 line of work." Lifts the doc from ad-hoc to situated.
- **Distinguish three equivalence strengths** in a short table (semantic / observational / structural) and state which one each verification step delivers. This pre-empts the reviewer's single sharpest objection (C2).
- **Connect §5 (ID assignment) to the O(1) claim** with one explicit sentence: dense sequential IDs are *why* the supervisor index is a flat-array lookup. Turns an asserted complexity into a derived property.
- **Add a "Threats to validity" subsection** - bounded test suite (C14), Stage-0-as-oracle means Stage-0 bugs become "correct" (§4.1 already implies this; make it explicit), and MLIR/LLVM version drift. Standard for publication-grade systems work.
- **MLIR anchor box.** One sidebar listing the three upstream mechanisms relied on (ODS, dialect verifiers, dialect-conversion to LLVM) with links, so the dialect docs (0019/0020) inherit external grounding.

---

## 4. Missing evidence / benchmark list

1. **The differential test corpus (C14) - required before §11 checkboxes can be ticked.** Need a named set of `.vaked` programs spanning: single-agent, linear chain, diamond (fan-out/fan-in), max-depth-bound boundary, and a known-cyclic (must-reject) case. Each runs Stage-0 and (eventually) Stage-1, canonicalizes, hashes, compares. Until this exists, "round-trip equivalence on a diverse test suite" is a *plan*, not *evidence*.
2. **Canonicalization spec.** §2.2 says "strip timestamps, sort arrays" - enumerate exactly which fields are non-deterministic in the supervisor-index JSON (token fields, any map iteration order). Reproducible-builds practice: make the list exhaustive or the comparison is unsound.
3. **O(1) lookup - no benchmark needed, but state the data structure.** A micro-benchmark would be theater here; the honest evidence is "dense integer IDs index a packed array." Document that, not a latency number.
4. **MLIR-version pin.** When Stage-1 lands, the ODS/verifier/lowering APIs are version-sensitive. Record the target LLVM/MLIR release as an assumption.
5. **(Optional, future) bounded translation validation.** If stronger-than-observational assurance is ever wanted, Alive2-style SMT validation applies only at the LLVM-IR tail of the pipeline, not at the `vaked`/`hcp` dialect level. Note as a non-goal with the reason.

---

## 5. Publication-ready rewritten section (proposed §2)

> ### 2. The lowering contract
>
> Stage-1 is a **translation-validated** reimplementation of the Stage-0 LPG pipeline in MLIR. "Translation-validated" is used in the sense established by Pnueli et al. and exercised by the LLVM Alive2 project: rather than proving the two pipelines equal in general, we validate that Stage-1 reproduces Stage-0 on every program in a reference corpus, with the executable Stage-0 passes as the oracle.
>
> #### 2.1 Observational equivalence (not general semantic equivalence)
>
> **Requirement.** For any `.vaked` source `P`, let `A_0 = {pass1(P), pass2(P), pass3(P)}` be the Stage-0 artifacts and `A_1` the Stage-1 artifacts. Stage-1 is correct on `P` when `A_1` is **observationally equivalent** to `A_0`: after canonicalization (§2.2) the two are identical in
> - agent topology (agents, dependencies, depths),
> - WAL sequence structure and order, and
> - supervisor-index agent IDs, subscriptions, and depths.
>
> We claim observational equivalence on the corpus, not general semantic equivalence: the latter is undecidable in the limit and, where tractable, demands bounded SMT translation validation (Alive2) or machine-checked proof (CompCert) - both out of scope for the dialect level (see §12, Threats to validity). Observational equivalence on a representative corpus is the appropriate and sufficient contract for a faithful reimplementation.
>
> #### 2.2 Reproducibility (deterministic, canonicalized comparison)
>
> **Requirement.** Both stages must be **reproducible builds**: compiling the same source in the same environment yields bit-for-bit identical artifacts *after canonicalization*. There is no non-determinism in graph traversal, ID assignment, or serialization.
>
> "Byte-identical" is meaningful only post-canonicalization, because artifacts legitimately embed non-reproducible inputs (timestamps, random session tokens). The canonicalization step removes exactly these:
> 1. Compile `P` with Stage-0 -> `A_0`; with Stage-1 -> `A_1`.
> 2. Canonicalize both: strip the enumerated non-deterministic fields (timestamps, tokens), sort all unordered collections.
> 3. Hash each canonical form.
> 4. The hashes must be equal.
>
> The set of stripped fields is specified exhaustively in the canonicalization appendix; an incomplete list makes the comparison unsound (a known reproducible-builds failure mode).
>
> #### 2.3 Verifier equivalence (via MLIR ODS)
>
> **Requirement.** The Stage-1 dialect verifiers enforce the same invariants as the Stage-0 type checker. These verifiers are not bespoke: they are declared in MLIR's Operation Definition Specification (ODS/TableGen), which generates the op classes and their verifier hooks. The mapping is
> - `vaked` dialect verifier <-> `vakedc` type checking + structure validation,
> - `hcp` dialect verifier <-> WAL discipline constraints (RFC 0004).
>
> Each invalid input Stage-0 rejects (consume of a nonexistent agent; a cycle; a WAL-ordering violation) must be rejected by the corresponding Stage-1 verifier.

(Sections §3-§13 are sound as written; only the C9<->C11 cross-link sentence in §5/§6 and a "Threats to validity" subsection in §12 are recommended. Full bodies omitted here to keep the artifact non-destructive.)

---

## 6. Suggested figures / tables

- **Fig. 1 - Equivalence-strength ladder.** Three rows (semantic / observational / structural), columns: definition, what verifies it, where 0024 uses it. Directly answers the reviewer's sharpest question.
- **Fig. 2 - Canonicalization pipeline.** `A_0`,`A_1` -> [strip non-det fields] -> [sort collections] -> [hash] -> compare. Makes §2.2 unambiguous.
- **Fig. 3 - Stage-0/Stage-1 correspondence.** Existing two ASCII pipelines (§1) redrawn side-by-side with the pass<->reference-code arrows (check.py / lower.py line ranges) as the bridge. Shows the oracle relationship at a glance.
- **Table A - Non-deterministic field inventory** for the supervisor-index JSON (field, source of variance, canonicalization action). Doubles as the §2.2 appendix.
- Reuse the existing §3.1 exclusion table verbatim - it is already publication quality.

---

## 7. Follow-up research tasks

1. **Build the differential corpus** (single / chain / diamond / depth-bound / cyclic) and wire Stage-0 round-trip + canonical-hash as a `task` target. Unblocks C14 and the §11 checklist. *(Design -> plan -> implement; build runs on dev-cx53, never locally.)*
2. **Write the canonicalization appendix** by enumerating non-deterministic fields in `vakedc/lower.py:1893-1953` index output. Static read - allowed locally.
3. **Add external anchors to 0019/0020** (ODS, dialect verifiers, dialect conversion) so the dialect specs inherit grounding; keeps the citation work where the implementable precision lives.
4. **Decide the equivalence bar for the LLVM tail.** If anything beyond observational equivalence is ever wanted, scope an Alive2-style bounded check at LLVM-IR only; record as explicit non-goal otherwise.
5. **Reconcile diagnostic naming** (`E-TOPO-CYCLE` vs `E-WORKFLOW-CYCLE`, 0013 open Q) before declaring verifier equivalence checkable.

---

## Appendix - research digests (primary sources, 2026-06-14)

**Probe A - MLIR dialect/verifier/lowering machinery.** ODS (Operation Definition Specification) is MLIR's table-driven, TableGen-based mechanism: a `.td` record expands to an `mlir::Op` C++ specialization and declares the op's verifier. Custom dialects are built from `FooOps.td`; lowering to LLVM uses a `ConversionTarget` + `TypeConverter`. Confirms C5/C6: the `vaked`/`hcp` verifier-equivalence and "TableGen-ready" claims are supported upstream mechanisms. Primary: [ODS](https://mlir.llvm.org/docs/DefiningDialects/Operations/), [Creating a Dialect](https://mlir.llvm.org/docs/Tutorials/CreatingADialect/), [Lowering to LLVM (Toy Ch.6)](https://mlir.llvm.org/docs/Tutorials/Toy/Ch-6/).

**Probe B - translation validation / equivalence checking.** "Translation validation" is the precise term for validating that a translated/recompiled program preserves the source's behavior (Pnueli et al., 1998). Alive2 performs *bounded* translation validation for LLVM IR via SMT, automatically, no LLVM changes - but bounds resources (e.g., unrolls loops) and so "there are circumstances in which it misses bugs"; it found 47 new LLVM bugs. CompCert achieves semantic preservation by Coq proof, with high manual overhead. Both are confined to a single IR and cannot verify equivalence across distinct high-level languages. Confirms C2 as overclaim: unqualified "semantically equivalent" is stronger than differential testing delivers; the honest claim is observational equivalence on a corpus. Primary: [Alive2, PLDI'21 (PDF)](https://users.cs.utah.edu/~regehr/alive2-pldi21.pdf), [ACM DL](https://dl.acm.org/doi/10.1145/3453483.3454030).

**Probe C - reproducible builds / determinism.** Canonical definition: "a build is reproducible if given the same source code, build environment and build instructions, any party can recreate bit-by-bit identical copies of all specified artifacts." Central challenge is eliminating non-determinism; named root causes include embedded timestamps, build paths, filesystem/archive ordering, and random numbers. Confirms C3/C4: 0024's "byte-identical (modulo timestamps)" is imprecise phrasing of *reproducible-after-canonicalization*; the §2.2 normalize-then-hash procedure is canonical practice; the field-standard fix is an exhaustive non-deterministic-field inventory. Primary: [reproducible-builds.org definition](https://reproducible-builds.org/docs/definition/), [reproducible-builds.org](https://reproducible-builds.org/).

*Method note: per the session's abstain-safe protocol, each probe sought primary sources and would mark a claim "unverified/abstain" (never auto-refute) on a fetch/rate-limit failure. No probe hit a rate limit; all three resolved against primary sources and confirmed (two with sharpening, none refuted).*

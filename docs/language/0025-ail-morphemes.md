---
doc: 0025
title: "AIL-0 morpheme table"
status: Experimental
track: Language
created: 2026-06-14
---

# 0025 — AIL-0 morpheme table

Status: **Experimental** · Series: language design notes · Track: Language

> AIL-0 (Agentic Intermediate Language, v0) is a register-tagged notation for
> LLM-agent communication. This doc lists every closed-set token in the grammar
> (`protocol/ail/ail-v0.ebnf`), grouped by role, with a one-concept gloss and
> the registers that use each token. Nothing here is invented: each row maps
> exactly to a terminal or keyword in the EBNF, with no additions and no omissions.

---

## Tokenizer note

The costs below are **tokenizer-observed, not tokenizer-perfect**: per-provider
token cost varies because different models use different BPE vocabularies (GPT
`cl100k_base`, `o200k_base`, Llama SentencePiece, etc.). The AIL-0 bench
(`docs/superpowers/specs/2026-06-14-ail-bench-design.md`) measures real
per-tokenizer savings so that savings claims are empirical rather than assumed.

All AIL-0 operators are ASCII. The research underlying this grammar
(`docs/superpowers/research/2026-06-14-ail-0-single-agent-research.md`, §3.3)
finds that rare-Unicode and CJK glyphs can *increase* token count via byte-fallback
tokenization -- for example, `cl100k_base` encodes most CJK ideographs as 2-3
tokens rather than 1, and rare Unicode arrows such as `->` Unicode forms can cost
2-4 tokens each depending on tokenizer vocab coverage. This is why AIL-0 operators
are normatively ASCII and Unicode forms are explicitly non-normative sugar.

---

## 1. Registers

Registers are written as `[R:name]` frame-openers. Eight registers, three body arms:
free-text (think, plan), English-gated (artifact, commit), structured (tool, risk,
review, bench).

| Token | Gloss | Register(s) |
|-------|-------|-------------|
| `R:think` | unconstrained reasoning scratch-pad | self |
| `R:plan` | unconstrained planning / sequencing | self |
| `R:artifact` | English-only output body (CJK excluded by grammar) | self |
| `R:commit` | English Conventional-Commit subject (CJK excluded) | self |
| `R:tool` | structured tool invocation with exact-path/symbol args | self |
| `R:risk` | structured risk or confidence annotation | self |
| `R:review` | structured review / diff annotation | self |
| `R:bench` | structured benchmark record | self |

---

## 2. Causal operators

These appear in `relation ::= atom op atom` inside structured frames.

| Token | Gloss | Register(s) |
|-------|-------|-------------|
| `->` | sequence / yields | R:tool, R:risk, R:review, R:bench |
| `=>` | implies / entails | R:tool, R:risk, R:review, R:bench |
| `bc` | because (causal antecedent) | R:tool, R:risk, R:review, R:bench |
| `so` | therefore (causal consequent) | R:tool, R:risk, R:review, R:bench |

---

## 3. Parallel / join operators

Also in `op`; express concurrency and merge semantics.

| Token | Gloss | Register(s) |
|-------|-------|-------------|
| `par` | parallel-with (concurrent execution) | R:tool, R:risk, R:review, R:bench |
| `merge` | join / reconcile two parallel branches | R:tool, R:risk, R:review, R:bench |
| `conflict` | irreconcilable merge (explicit collision) | R:tool, R:risk, R:review, R:bench |

---

## 4. Comparison operators

The remaining four members of the `op` production; used for value comparisons in relations.

| Token | Gloss | Register(s) |
|-------|-------|-------------|
| `!=` | not equal | R:tool, R:risk, R:review, R:bench |
| `~=` | approximately equal | R:tool, R:risk, R:review, R:bench |
| `<=` | less than or equal | R:tool, R:risk, R:review, R:bench |
| `>=` | greater than or equal | R:tool, R:risk, R:review, R:bench |

---

## 5. Gate names

`gate(name:state)` records an output-discipline or pipeline check. The closed set
of names is defined in `gate_name` in the EBNF.

| Token | Gloss | Register(s) |
|-------|-------|-------------|
| `artifact` | output-discipline: body must be English, no CJK | any structured frame |
| `english` | output-discipline: English-only content check | any structured frame |
| `no_cjk` | output-discipline: explicit CJK-exclusion assertion | any structured frame |
| `ci` | pipeline check: CI/CD pass/fail record | any structured frame |
| `bench` | pipeline check: benchmark result record | any structured frame |
| `parse` | pipeline check: grammar parse outcome | any structured frame |

---

## 6. Gate states

The closed set of outcomes for any `gate(name:state)` expression, defined in
`gate_state` in the EBNF.

| Token | Gloss | Register(s) |
|-------|-------|-------------|
| `pass` | check succeeded | any structured frame |
| `fail` | check failed | any structured frame |
| `warn` | check passed with a warning | any structured frame |
| `skip` | check not run (intentionally bypassed) | any structured frame |

---

## Coverage check

| EBNF closed set | Count | Rows above |
|-----------------|-------|-----------|
| `register` (all 8) | 8 | Section 1 |
| `op` (all 11) | 11 | Sections 2, 3, 4 |
| `gate_name` (all 6) | 6 | Section 5 |
| `gate_state` (all 4) | 4 | Section 6 |
| **Total** | **29** | **29** |

No EBNF terminal is absent from this table. No row in this table is absent from
the EBNF. Total entries (29) are well within the 80-entry limit.

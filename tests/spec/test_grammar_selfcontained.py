#!/usr/bin/env python3
"""test_grammar_selfcontained.py — every grammar RHS nonterminal is defined, and
no rule is dead except a documented allowlist.

Guards: a grammar edit that references an undefined nonterminal, or that orphans a
rule (leaves it unreachable from the start symbol), is caught here. Both `.ebnf`
files are read FROM DISK so this exercises the real spec artifacts.

Allowlists (documented dead rules):
  vaked    : comment, any, eol   — `comment` is stripped by the lexer and defined
                                    "for completeness" (grammar §Lexical terminals);
                                    `any`/`eol` are referenced only by `comment`, so
                                    they are transitively dead too.
  hcplang  : (none)              — every rule is reachable from `schema`, including
                                    `string_char` (reached via `string`). The
                                    allowlist is intentionally empty; the check below
                                    also fails if an allowlist entry is in fact live,
                                    so the allowlists cannot silently rot.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ebnf  # noqa: E402
import lex_vaked  # noqa: E402
import lex_hcplang  # noqa: E402

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
VAKED_GRAMMAR = os.path.join(REPO, "vaked", "grammar", "vaked-v0-plus.ebnf")
HCP_GRAMMAR = os.path.join(REPO, "protocol", "hcplang", "grammar.ebnf")

# Allowlisted dead rules per grammar (see module docstring).
VAKED_DEAD_ALLOW = {"comment", "any", "eol"}
HCP_DEAD_ALLOW = set()  # hcplang has no unreachable rules


def _check_grammar(path, start, terminal_names, dead_allow):
    g = ebnf.Grammar.load(path, start=start)
    failures = []

    # (1) Every RHS nonterminal is defined OR is a known terminal name.
    undef = g.undefined_refs(terminal_names)
    if undef:
        for rule, missing in sorted(undef.items()):
            failures.append(
                f"rule {rule!r} references undefined nonterminal(s): "
                f"{sorted(missing)}"
            )

    # (2) Dead rules (unreachable from start) must be within the allowlist.
    dead = g.dead_rules()
    unexpected_dead = dead - dead_allow
    if unexpected_dead:
        failures.append(
            f"unexpected dead (unreachable) rule(s): {sorted(unexpected_dead)} "
            f"(allowlist = {sorted(dead_allow)})"
        )
    # Also flag a STALE allowlist: a rule we allow as dead that is actually live
    # (keeps the allowlist honest as the grammar evolves).
    stale = dead_allow - dead
    if stale:
        failures.append(
            f"allowlist lists rule(s) as dead that are actually reachable: "
            f"{sorted(stale)} — tighten the allowlist"
        )

    return g, dead, failures


def run():
    """Return (ok: bool, lines: list[str]) summarizing the checks."""
    lines = []
    ok = True

    # vaked terminal names = lexer's TERMINAL_MAP keys (names the lexer realizes).
    g_v, dead_v, fv = _check_grammar(
        VAKED_GRAMMAR, "file", set(lex_vaked.TERMINAL_MAP), VAKED_DEAD_ALLOW
    )
    lines.append(f"vaked grammar: {len(g_v.rules)} rules, "
                 f"dead={sorted(dead_v)} (allowed)")
    for f in fv:
        ok = False
        lines.append(f"  FAIL: {f}")

    g_h, dead_h, fh = _check_grammar(
        HCP_GRAMMAR, "schema", set(lex_hcplang.TERMINAL_MAP), HCP_DEAD_ALLOW
    )
    lines.append(f"hcplang grammar: {len(g_h.rules)} rules, "
                 f"dead={sorted(dead_h)} (allowed)")
    for f in fh:
        ok = False
        lines.append(f"  FAIL: {f}")

    return ok, lines


if __name__ == "__main__":
    ok, lines = run()
    print("== test_grammar_selfcontained ==")
    for ln in lines:
        print(ln)
    print("RESULT:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)

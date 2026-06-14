#!/usr/bin/env python3
"""run_all.py — run every spec-test module, print a per-test summary table, and
exit non-zero on any failure.

Run from the repo root (or anywhere):

    python3 tests/spec/run_all.py

Each test module exposes ``run() -> (ok: bool, lines: list[str])``. This driver
calls them in order, prints each module's detail lines, then a summary table, and
sets the process exit code to 1 if any module failed (so CI fails the job).
"""

import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import test_grammar_selfcontained as t_grammar  # noqa: E402
import test_examples_parse as t_examples  # noqa: E402
import test_lowering_fixtures as t_lowering  # noqa: E402
import test_doc_links as t_links  # noqa: E402
import test_vakedc as t_vakedc  # noqa: E402
import test_vakedc_check as t_vakedc_check  # noqa: E402
import test_vakedc_lower as t_vakedc_lower  # noqa: E402
import test_agentfield_load as t_af_load  # noqa: E402
import test_eventd as t_eventd  # noqa: E402
import test_otp_lowering as t_otp  # noqa: E402
import test_agentfield_lowering as t_af_lower  # noqa: E402
import test_agent_guardd as t_guardd  # noqa: E402
import test_yardmaster as t_yardmaster  # noqa: E402
import test_telebot as t_telebot  # noqa: E402
import test_swe_af_workflow as t_swe_af_wf  # noqa: E402

ALL_MODULES = [
    ("grammar_selfcontained", t_grammar),
    ("examples_parse",        t_examples),
    ("lowering_fixtures",     t_lowering),
    ("doc_links",             t_links),
    ("vakedc",                t_vakedc),
    ("vakedc_check",          t_vakedc_check),
    ("vakedc_lower",          t_vakedc_lower),
    ("agentfield_load",       t_af_load),
    ("eventd",                t_eventd),
    ("otp_lowering",          t_otp),
    ("agentfield_lowering",   t_af_lower),
    ("agent_guardd",          t_guardd),
    ("yardmaster",            t_yardmaster),
    ("telebot",               t_telebot),
    ("swe_af_workflow",       t_swe_af_wf),
]

# Tier subsets used by ci-gate:
#   smoke    – grammar + examples + doc_links (always runs, <60s)
#   standard – smoke + lowering + vakedc parse/check + eventd (~3 min)
#   full     – all 14 tests (~8 min, default)
SMOKE_NAMES = {"grammar_selfcontained", "examples_parse", "doc_links"}
STANDARD_NAMES = SMOKE_NAMES | {"lowering_fixtures", "vakedc", "vakedc_check", "eventd"}

TIER_MODULES = {
    "smoke":    [m for m in ALL_MODULES if m[0] in SMOKE_NAMES],
    "standard": [m for m in ALL_MODULES if m[0] in STANDARD_NAMES],
    "full":     ALL_MODULES,
}
# Aliases
TIER_MODULES["extended"] = TIER_MODULES["full"]
MODULES = ALL_MODULES  # backwards-compat


def main():
    import argparse
    ap = argparse.ArgumentParser(description="Vaked spec-test harness")
    ap.add_argument(
        "--tier",
        choices=list(TIER_MODULES),
        default="full",
        help="Test subset to run (default: full)",
    )
    args, _ = ap.parse_known_args()

    modules = TIER_MODULES[args.tier]

    print("=" * 72)
    print(f"Vaked spec-test harness — tests/spec/run_all.py  [tier={args.tier}, {len(modules)} modules]")
    print("=" * 72)

    results = []
    for name, mod in modules:
        t0 = time.time()
        try:
            ok, lines = mod.run()
            err = None
        except Exception as e:  # a test module crashing is itself a failure
            ok, lines, err = False, [], f"{type(e).__name__}: {e}"
        dt = time.time() - t0

        print(f"\n## {name}")
        for ln in lines:
            print(ln)
        if err is not None:
            import traceback
            print(f"  ERROR: {err}")
            traceback.print_exc()
        print(f"  ({'PASS' if ok else 'FAIL'} in {dt*1000:.0f} ms)")
        results.append((name, ok, dt))

    # summary table
    print("\n" + "=" * 72)
    print("SUMMARY")
    print("-" * 72)
    width = max(len(n) for n, _, _ in results)
    n_pass = 0
    for name, ok, dt in results:
        status = "PASS" if ok else "FAIL"
        if ok:
            n_pass += 1
        print(f"  {name.ljust(width)}   {status}   {dt*1000:7.0f} ms")
    print("-" * 72)
    all_ok = (n_pass == len(results))
    print(f"  {n_pass}/{len(results)} test modules passed   "
          f"=> {'ALL GREEN' if all_ok else 'FAILURES PRESENT'}")
    print("=" * 72)
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())

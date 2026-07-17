#!/usr/bin/env bash
# crossverify — the closed-loop dogfooding gate for vakedz.
#
# WHAT THIS IS NOW (rewritten 2026-07-17, Zig rewrite plan Task 17)
# ----------------------------------------------------------------
# A thin aggregate runner over the FOUR differential harnesses that are the
# port's real parity contract:
#
#   tools/check-diff/run.sh    checker   — diagnostics (messages+spans+order)
#   tools/emit-diff/run.sh     emitter   — canonical graph JSON, byte parity
#   tools/lower-diff/run.sh    lowerer   — artifact tree, byte parity
#   tools/passes-diff/run.sh   passes    — topology→WAL→AOT, byte parity
#
# Each compares vakedz against the Python reference (vakedc) across the corpus
# and exits non-zero on any mismatch, naming the offending files. This script
# runs all four, does not stop at the first failure, and reports a per-harness
# verdict so a red run names the harness immediately.
#
# WHY THE OLD IMPLEMENTATION WAS RETIRED
# --------------------------------------
# The previous crossverify hand-rolled two gates that the harnesses above now
# subsume, and it had rotted:
#
#   * It ran `vakedz parse --no-cache`. That flag no longer exists, so EVERY
#     invocation died with "expected exactly one file" — the script could not
#     pass at all.
#   * Its golden gate diffed `vakedz parse` against two committed snapshots in
#     vakedz/test/golden/. emit-diff compares vakedz against the LIVE vakedc
#     reference on all 58 corpus files — a strict superset, and one that cannot
#     rot the way a committed snapshot can.
#   * Its check gate projected diagnostics to `code:severity:line:col`.
#     check-diff does exactly that sweep AND adds two probe files gated on full
#     message text, so message-string parity is regression-locked.
#   * It swallowed reference failures (`python3 -m vakedc parse ... || true`)
#     and had a SKIP bucket that only warned when ALL files skipped — i.e. a
#     totally broken vakedc could yield a green run. The harnesses treat a
#     one-sided failure as a hard mismatch and enforce a MIN_FILES floor, so a
#     silently-empty sweep can never pass.
#
# The goldens under vakedz/test/golden/ have no remaining consumer.
#
# Usage:  vakedz/test/crossverify.sh [path/to/vakedz]
#
# Environment (forwarded to every harness):
#   VAKEDZ  path to the vakedz binary   (default: ./zig-out/bin/vakedz,
#                                        or $1 when given)
#   PYTHON  python interpreter          (default: python3)
#
# vakedc is stdlib-only and is imported as `python3 -m vakedc` from the repo
# root — no `pip install` is required.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 2

VAKEDZ="${1:-${VAKEDZ:-$ROOT/zig-out/bin/vakedz}}"
export VAKEDZ
export PYTHON="${PYTHON:-python3}"

if [[ ! -x "$VAKEDZ" ]]; then
  echo "crossverify: vakedz binary not found at '$VAKEDZ' (run: zig build)" >&2
  exit 2
fi

HARNESSES=(check-diff emit-diff lower-diff passes-diff)

failed=()
for h in "${HARNESSES[@]}"; do
  echo "=========================================================="
  echo "crossverify: running tools/$h/run.sh"
  echo "=========================================================="
  if bash "tools/$h/run.sh"; then
    echo "crossverify: PASS  $h"
  else
    rc=$?
    echo "crossverify: FAIL  $h (exit $rc)" >&2
    failed+=("$h")
  fi
  echo
done

echo "=========================================================="
if [[ ${#failed[@]} -eq 0 ]]; then
  echo "crossverify: OK — vakedz matches the vakedc reference on all four differentials"
  exit 0
fi
echo "crossverify: FAILED — ${#failed[@]}/${#HARNESSES[@]} differential(s) mismatched: ${failed[*]}" >&2
echo "crossverify: see the per-harness output above for the offending files" >&2
exit 1

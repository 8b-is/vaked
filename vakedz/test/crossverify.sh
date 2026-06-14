#!/usr/bin/env bash
# crossverify — the closed-loop dogfooding gate for vakedz.
#
# Builds nothing; takes a path to the vakedz binary, runs `vakedz parse` on each
# example whose graph we have a committed golden for, and asserts byte-identical
# output. Also re-derives each golden from the Python reference (`vakedc parse`)
# and warns if the committed golden has drifted from it — so the Zig front-end
# and the Python reference are pinned to the SAME bytes, forever.
#
# Check parity gate: runs `vakedz check --json` on all vaked/examples/**/*.vaked
# files and diffs output byte-for-byte against `python3 -m vakedc check --json`.
# Any mismatch is a CI failure.
#
# Usage:  vakedz/test/crossverify.sh [path/to/vakedz]
set -euo pipefail

BIN="${1:-vakedz/zig-out/bin/vakedz}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

if [[ ! -x "$BIN" ]]; then
  echo "crossverify: vakedz binary not found at '$BIN' (run: cd vakedz && zig build)" >&2
  exit 2
fi

# source.vaked  ->  committed golden graph
PAIRS=(
  "vaked/examples/operator-field.vaked|vakedz/test/golden/operator-field.graph.json"
  "vaked/examples/engines/zig.vaked|vakedz/test/golden/zig.graph.json"
)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

for pair in "${PAIRS[@]}"; do
  src="${pair%%|*}"
  golden="${pair##*|}"
  out="$tmp/$(basename "$golden")"

  "$BIN" parse "$src" --json "$out" --no-cache >/dev/null
  if diff -u "$golden" "$out" >"$tmp/diff.txt"; then
    echo "PASS  vakedz parse $src == $golden"
  else
    echo "FAIL  vakedz parse $src != $golden"
    sed 's/^/      /' "$tmp/diff.txt" | head -40
    fail=1
  fi

  # Drift guard: the committed golden must still equal the Python reference.
  if command -v python3 >/dev/null 2>&1 && [[ -d vakedc ]]; then
    ref="$tmp/ref-$(basename "$golden")"
    python3 -m vakedc parse "$src" --json "$ref" 2>/dev/null || true
    if [[ -f "$ref" ]] && ! diff -q "$golden" "$ref" >/dev/null; then
      echo "WARN  golden $golden has drifted from the vakedc reference — regenerate it"
      fail=1
    fi
  fi
done

# ---------------------------------------------------------------------------
# Check parity gate: vakedz check --json  ==  python3 -m vakedc check --json
# (byte-identical) on every vaked/examples/**/*.vaked file.
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1 && [[ -d vakedc ]]; then
  # Collect all example files.
  mapfile -t EXAMPLES < <(find vaked/examples -name '*.vaked' | sort)

  check_skip=0
  for example in "${EXAMPLES[@]}"; do
    slug="$(echo "$example" | tr '/.' '-')"
    zig_out="$tmp/check-zig-${slug}.json"
    py_out="$tmp/check-py-${slug}.json"

    # Run Zig checker; capture exit code manually (exit 1 = diagnostics found,
    # which is valid; exit 2+ = internal error).  The `|| true` keeps set -e
    # happy; we inspect the real rc via the assignment.
    zig_rc=0
    "$BIN" check --json "$example" >"$zig_out" 2>/dev/null || zig_rc=$?
    if [[ $zig_rc -ge 2 ]]; then
      echo "FAIL  vakedz check $example exited with error code $zig_rc"
      fail=1
      continue
    fi

    # Run Python reference checker.
    py_rc=0
    python3 -m vakedc check --json "$example" >"$py_out" 2>/dev/null || py_rc=$?
    if [[ $py_rc -ge 2 ]]; then
      echo "SKIP  vakedc check $example exited with error $py_rc (skipping parity for this file)"
      check_skip=$((check_skip + 1))
      continue
    fi

    if diff -u "$py_out" "$zig_out" >"$tmp/check-diff.txt"; then
      echo "PASS  check-parity $example"
    else
      echo "FAIL  check-parity $example — vakedz and vakedc disagree"
      sed 's/^/      /' "$tmp/check-diff.txt" | head -60
      fail=1
    fi
  done

  if [[ ${#EXAMPLES[@]} -eq 0 ]]; then
    echo "WARN  no vaked/examples/**/*.vaked files found — check parity gate skipped"
  elif [[ $check_skip -eq ${#EXAMPLES[@]} ]]; then
    echo "WARN  all check-parity runs were skipped (vakedc unavailable?)"
  fi
else
  echo "SKIP  check parity gate (python3 / vakedc not available)"
fi

if [[ "$fail" -eq 0 ]]; then
  echo "crossverify: OK — vakedz is byte-identical to vakedc on all goldens"
else
  echo "crossverify: FAILED" >&2
fi
exit "$fail"

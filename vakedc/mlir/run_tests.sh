#!/usr/bin/env bash
# run_tests.sh — verify MLIR dialect passes and round-trip
# Called by `ninja check-vaked-mlir`.
set -euo pipefail

echo "=== vaked MLIR dialect tests ==="

BUILD_DIR="${BUILD_DIR:-$(dirname "$0")/build}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Test 1: TableGen generates valid output
echo "--- Test: TableGen generates vaked dialect ---"
mlir-tblgen --gen-dialect-decls "${SCRIPT_DIR}/VakedDialect.td" > /dev/null
echo "  PASS: vaked dialect declarations"

mlir-tblgen --gen-op-defs "${SCRIPT_DIR}/VakedDialect.td" > /dev/null
echo "  PASS: vaked dialect ops"

mlir-tblgen --gen-dialect-decls "${SCRIPT_DIR}/HcpDialect.td" > /dev/null
echo "  PASS: hcp dialect declarations"

mlir-tblgen --gen-op-defs "${SCRIPT_DIR}/HcpDialect.td" > /dev/null
echo "  PASS: hcp dialect ops"

# Test 2: Verify Stage-0 pass pipeline is importable
echo "--- Test: Stage-0 Python passes import ---"
python3 -c "from vakedc.passes import PassPipeline; print('  PASS: PassPipeline import OK')" 2>/dev/null

# Test 3: Verify 0024 corpus
echo "--- Test: 0024 corpus ---"
python3 "${SCRIPT_DIR}/../../tests/corpus/0024-differential/run_corpus.py"

echo ""
echo "=== all vaked MLIR tests PASS ==="

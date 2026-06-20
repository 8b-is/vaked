# MLIR dialect definitions — Stage-1 TableGen specs

These TableGen `.td` files define the two MLIR dialects for Vaked's multi-agent
topology compilation pipeline, specified in design docs 0019–0024.

## Architecture

```
vaked dialect (high-level topology)         0019
    ↓ Pass 1: topology analysis (cycle, depth, bound)  0021
    ↓ Pass 2: WAL injection (vaked → hcp lowering)     0022
hcp dialect (low-level orchestration)       0020
    ↓ Pass 3: AOT supervisor index generation          0023
    ↓ LLVM lowering → codegen
compiled agent binaries + supervisor index
```

## Files

| File | Defines |
|------|---------|
| `VakedDialect.td` | `vaked` dialect, types (`!vaked.state_hash`, `!vaked.agent_id`, `!vaked.state<S>`), ops (`vaked.agent`, `vaked.yield`, `vaked.execute_step`, `vaked.consume`, `vaked.execute_with_dep`) |
| `HcpDialect.td` | `hcp` dialect, types (`!hcp.token`, `!hcp.hash`, `!hcp.data<T>`), ops (`hcp.create_registration_token`, `hcp.write_ahead_log`, `hcp.fetch_canonical_data`, `hcp.rewind_scope`) |
| `VakedDialect.cpp` | C++ dialect registration + verifier implementations for vaked dialect |
| `HcpDialect.cpp` | C++ dialect registration for hcp dialect |
| `CMakeLists.txt` | CMake build: mlir-tblgen → .inc files, dialect library, test target |
| `run_tests.sh` | Test script: TableGen output validation + Stage-0 corpus check |

## Status

**Stage 1 — Buildable (requires MLIR toolchain).** These files define the
complete MLIR dialect pipeline. `flake.nix` includes `llvmPackages_latest.mlir`
in the dev shell. To build:

```bash
# Enter nix dev shell and build
nix develop .
cd vakedc/mlir
mkdir -p build && cd build
cmake -G Ninja .. -DMLIR_DIR=$(mlir-tblgen --print-mlir-dir 2>/dev/null || echo "$(dirname $(which mlir-tblgen))/../lib/cmake/mlir")
ninja
ninja check-vaked-mlir
```

The TableGen `.td` files are valid MLIR-ODS syntax that `mlir-tblgen` compiles
into C++ dialect classes (`.h.inc` / `.cpp.inc`). The `.cpp` files bridge
those generated classes with MLIR's runtime dialect registry and add verifier
logic. The CMake build orchestrates the full pipeline.

```bash
# From a build directory with LLVM/MLIR in the CMake prefix path:
mlir-tblgen --gen-dialect-decls VakedDialect.td > VakedDialect.h.inc
mlir-tblgen --gen-op-defs       VakedDialect.td > VakedDialect.cpp.inc
mlir-tblgen --gen-dialect-decls HcpDialect.td   > HcpDialect.h.inc
mlir-tblgen --gen-op-defs       HcpDialect.td   > HcpDialect.cpp.inc
```

## Cross-reference

- Stage-0 reference: `vakedc/passes/` (Python pass pipeline)
- Stage-1 spec: docs 0019 (vaked dialect), 0020 (hcp dialect), 0021–0023 (passes)
- Adoption contract: 0024 (lowering contract, staged adoption)
- Issue: [#23](https://github.com/peterlodri-sec/vaked-base/issues/23)

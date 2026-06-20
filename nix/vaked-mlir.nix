{ lib, stdenv, cmake, ninja, git, fetchFromGitHub, ... }:

# Builds mlir-tblgen from source, then compiles the Vaked MLIR dialect library.
#
# Note: nixpkgs' llvmPackages_latest.mlir ships the MLIR runtime libraries
# but NOT mlir-tblgen (the TableGen compiler for MLIR dialects). This derivation
# builds mlir-tblgen from LLVM source as a first step, then reuses the pre-built
# MLIR libraries from nixpkgs for compilation.
#
# Slow on first build (~5 min for mlir-tblgen). Use tools/build-mlir-stage1.sh
# for an alternative build path.

let
  llvmVersion = "22.1.7";
in

stdenv.mkDerivation {
  pname = "vaked-mlir";
  version = "0.1.0";

  src = ./../.;

  # Use fetchFromGitHub instead of git clone (avoids SSL cert issues on some hosts).
  llvm_src = fetchFromGitHub {
    owner = "llvm";
    repo = "llvm-project";
    rev = "llvmorg-${llvmVersion}";
    sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; # BROKEN: fixed-output hash not yet computed — run on dev-cx53 via the 3-gate build protocol (nix build .#vaked-mlir 2>&1 | grep 'got:'), paste the real sha256 here, then remove meta.broken. Do NOT build on the M1 dev machine.
  };

  nativeBuildInputs = [ cmake ninja git llvm_src ];

  phases = [ "buildPhase" "installPhase" ];

  buildPhase = ''
    echo "=== vaked-mlir: building MLIR dialects ==="
    export REPO_ROOT="$PWD"
    export BUILD_DIR="$TMPDIR/build"

    # Step 1: Build mlir-tblgen from LLVM source
    MLIR_SRC="${llvm_src}"
    echo "  LLVM source: ${llvm_src}"

    MLIR_BUILD="$TMPDIR/mlir-build"
    mkdir -p "$MLIR_BUILD"
    cmake -G Ninja -S "$MLIR_SRC/mlir" -B "$MLIR_BUILD" \
      -DLLVM_TARGETS_TO_BUILD="Native" \
      -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
      -DCMAKE_BUILD_TYPE=Release
    ninja -C "$MLIR_BUILD" -j$(nproc) mlir-tblgen 2>&1 | tail -3
    MLIR_TBLGEN="$MLIR_BUILD/bin/mlir-tblgen"
    echo "mlir-tblgen: $MLIR_TBLGEN"

    # Step 2: TableGen -> .inc files
    mkdir -p "$BUILD_DIR/generated"
    for td in "$REPO_ROOT/vakedc/mlir/"*.td; do
      baseName=$(basename "$td" .td)
      "$MLIR_TBLGEN" --gen-dialect-decls -dialect "$(echo "$baseName" | sed 's/Dialect//' | tr '[:upper:]' '[:lower:]')" \
        "$td" -o "$BUILD_DIR/generated/''${baseName}.h.inc"
      "$MLIR_TBLGEN" --gen-op-defs \
        "$td" -o "$BUILD_DIR/generated/''${baseName}.cpp.inc"
    done

    # Step 3: Build dialect library
    cmake -G Ninja \
      -DMLIR_DIR="$MLIR_BUILD/lib/cmake/mlir" \
      -DMLIR_TBLGEN="$MLIR_TBLGEN" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$out" \
      -DCMAKE_INSTALL_LIBDIR=lib \
      -DCMAKE_INSTALL_INCLUDEDIR=include \
      -S "$REPO_ROOT/vakedc/mlir" -B "$BUILD_DIR/cmake"
    ninja -C "$BUILD_DIR/cmake" -j$(nproc) VakedMLIRDialects
    ninja -C "$BUILD_DIR/cmake" install
  '';

  installPhase = ''
    # Already done by ninja install above; this is a no-op to satisfy Nix.
    mkdir -p "$out"
  '';

  meta = {
    description = "Vaked MLIR dialect library — built from source";
    longDescription = ''
      Builds the Vaked MLIR dialect library (vaked + hcp dialects).
      Compiles mlir-tblgen from LLVM ${llvmVersion} source, generates
      TableGen output from the .td dialect definitions, then compiles
      the C++ dialect library.

      Slow on first build (~5 min). Alternative: tools/build-mlir-stage1.sh
      Marked broken: the LLVM source fixed-output hash is a placeholder; compute it on dev-cx53 before enabling.
    '';
    homepage = "https://github.com/peterlodri-sec/vaked-base";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    broken = true;
  };
}

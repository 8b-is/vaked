#===-- CMakeLists.txt - Vaked MLIR dialect standalone build -----*- cmake -*-===//
#
# Standalone build for the vaked + hcp MLIR dialects. Uses mlir-tblgen and
# the MLIR libraries from a pre-built MLIR installation.
#
# Usage:
#   cmake -G Ninja .. -DMLIR_DIR=<mlir-prefix>/lib/cmake/mlir
#   ninja VakedMLIRDialects
#
#===----------------------------------------------------------------------===//

cmake_minimum_required(VERSION 3.20)
project(vaked-mlir LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Find MLIR — provides MLIR_INCLUDE_DIRS and MLIR_LIBS.
find_package(MLIR REQUIRED CONFIG)
message(STATUS "MLIR: ${MLIR_DIR}")
message(STATUS "MLIR include: ${MLIR_INCLUDE_DIRS}")

# Derive LLVM include path from the first MLIR include dir.
# MLIR includes are at: <llvm-project-root>/mlir/include/
list(GET MLIR_INCLUDE_DIRS 0 _FIRST_MLIR_INC)
get_filename_component(_MLIR_PARENT "${_FIRST_MLIR_INC}" DIRECTORY)
get_filename_component(_LLVM_PROJ_ROOT "${_MLIR_PARENT}" DIRECTORY)
set(LLVM_INCLUDE_DIR "${_LLVM_PROJ_ROOT}/llvm/include")
if(NOT EXISTS "${LLVM_INCLUDE_DIR}")
  # Fallback: try build-tree llvm from MLIR_DIR.
  get_filename_component(_MLIR_PARENT2 "${MLIR_DIR}/../../.." ABSOLUTE)
  set(LLVM_INCLUDE_DIR "${_MLIR_PARENT2}/llvm/include")
endif()
message(STATUS "LLVM include: ${LLVM_INCLUDE_DIR}")

# LLVM build-tree generated headers (llvm-config.h etc).
get_filename_component(_MLIR_BIN_PREFIX "${MLIR_DIR}/../../.." ABSOLUTE)
set(LLVM_BINARY_DIR "${_MLIR_BIN_PREFIX}")
if(NOT EXISTS "${LLVM_BINARY_DIR}/include/llvm/Config/llvm-config.h")
  # Not built in-tree; try the MLIR build prefix.
  set(LLVM_BINARY_DIR "${_MLIR_BIN_PREFIX}")
endif()
message(STATUS "LLVM binary: ${LLVM_BINARY_DIR}")

# Locate mlir-tblgen.
find_program(MLIR_TBLGEN mlir-tblgen REQUIRED)
message(STATUS "mlir-tblgen: ${MLIR_TBLGEN}")

# ---------------------------------------------------------------------------//
# TableGen: manually run mlir-tblgen to generate .inc files
# ---------------------------------------------------------------------------//

set(TD_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
set(GEN_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")

file(MAKE_DIRECTORY "${GEN_DIR}")

# Convert MLIR include dirs to -I flags for mlir-tblgen.
set(MLIR_TBLGEN_FLAGS "")
foreach(_dir ${MLIR_INCLUDE_DIRS})
  list(APPEND MLIR_TBLGEN_FLAGS "-I${_dir}")
endforeach()
list(APPEND MLIR_TBLGEN_FLAGS "-I${TD_DIR}")
list(APPEND MLIR_TBLGEN_FLAGS "-I${LLVM_INCLUDE_DIR}")
list(APPEND MLIR_TBLGEN_FLAGS "-I${LLVM_BINARY_DIR}/include")

# Vaked dialect
add_custom_command(OUTPUT "${GEN_DIR}/VakedDialect.h.inc"
  COMMAND ${MLIR_TBLGEN} --gen-dialect-decls -dialect vaked
    ${MLIR_TBLGEN_FLAGS}
    "${TD_DIR}/VakedDialect.td" -o "${GEN_DIR}/VakedDialect.h.inc"
  DEPENDS "${TD_DIR}/VakedDialect.td"
  COMMENT "Generating VakedDialect.h.inc"
)

add_custom_command(OUTPUT "${GEN_DIR}/VakedDialect.cpp.inc"
  COMMAND ${MLIR_TBLGEN} --gen-op-defs
    ${MLIR_TBLGEN_FLAGS}
    "${TD_DIR}/VakedDialect.td" -o "${GEN_DIR}/VakedDialect.cpp.inc"
  DEPENDS "${TD_DIR}/VakedDialect.td"
  COMMENT "Generating VakedDialect.cpp.inc"
)

# Op declarations (consumed by VakedDialect.h via the ODS op classes).
add_custom_command(OUTPUT "${GEN_DIR}/VakedDialectOps.h.inc"
  COMMAND ${MLIR_TBLGEN} --gen-op-decls
    ${MLIR_TBLGEN_FLAGS}
    "${TD_DIR}/VakedDialect.td" -o "${GEN_DIR}/VakedDialectOps.h.inc"
  DEPENDS "${TD_DIR}/VakedDialect.td"
  COMMENT "Generating VakedDialectOps.h.inc"
)

# TypeDef declarations (consumed by VakedDialect.h via the ODS type classes).
add_custom_command(OUTPUT "${GEN_DIR}/VakedDialectTypes.h.inc"
  COMMAND ${MLIR_TBLGEN} --gen-typedef-decls
    ${MLIR_TBLGEN_FLAGS}
    "${TD_DIR}/VakedDialect.td" -o "${GEN_DIR}/VakedDialectTypes.h.inc"
  DEPENDS "${TD_DIR}/VakedDialect.td"
  COMMENT "Generating VakedDialectTypes.h.inc"
)

# Generate type-only variants filtering out EXPLICIT_TYPE_ID to avoid
# duplicate when the same .inc is included twice (once for GET_OP_CLASSES,
# once for GET_TYPEDEF_LIST). MLIR 19+ generates these unconditionally.
add_custom_command(OUTPUT "${GEN_DIR}/VakedDialectTypes.cpp.inc"
  COMMAND grep -v MLIR_DEFINE_EXPLICIT_TYPE_ID
    "${GEN_DIR}/VakedDialect.cpp.inc"
    > "${GEN_DIR}/VakedDialectTypes.cpp.inc"
  DEPENDS "${GEN_DIR}/VakedDialect.cpp.inc"
  COMMENT "Filtering VakedDialect types .inc"
)

add_custom_command(OUTPUT "${GEN_DIR}/HcpDialectTypes.cpp.inc"
  COMMAND grep -v MLIR_DEFINE_EXPLICIT_TYPE_ID
    "${GEN_DIR}/HcpDialect.cpp.inc"
    > "${GEN_DIR}/HcpDialectTypes.cpp.inc"
  DEPENDS "${GEN_DIR}/HcpDialect.cpp.inc"
  COMMENT "Filtering HcpDialect types .inc"
)

# Hcp dialect
add_custom_command(OUTPUT "${GEN_DIR}/HcpDialect.h.inc"
  COMMAND ${MLIR_TBLGEN} --gen-dialect-decls -dialect hcp
    ${MLIR_TBLGEN_FLAGS}
    "${TD_DIR}/HcpDialect.td" -o "${GEN_DIR}/HcpDialect.h.inc"
  DEPENDS "${TD_DIR}/HcpDialect.td"
  COMMENT "Generating HcpDialect.h.inc"
)

add_custom_command(OUTPUT "${GEN_DIR}/HcpDialect.cpp.inc"
  COMMAND ${MLIR_TBLGEN} --gen-op-defs
    ${MLIR_TBLGEN_FLAGS}
    "${TD_DIR}/HcpDialect.td" -o "${GEN_DIR}/HcpDialect.cpp.inc"
  DEPENDS "${TD_DIR}/HcpDialect.td"
  COMMENT "Generating HcpDialect.cpp.inc"
)

# Op declarations (consumed by HcpDialect.h via the ODS op classes).
add_custom_command(OUTPUT "${GEN_DIR}/HcpDialectOps.h.inc"
  COMMAND ${MLIR_TBLGEN} --gen-op-decls -dialect hcp
    ${MLIR_TBLGEN_FLAGS}
    "${TD_DIR}/HcpDialect.td" -o "${GEN_DIR}/HcpDialectOps.h.inc"
  DEPENDS "${TD_DIR}/HcpDialect.td"
  COMMENT "Generating HcpDialectOps.h.inc"
)

# TypeDef declarations (consumed by HcpDialect.h via the ODS type classes).
add_custom_command(OUTPUT "${GEN_DIR}/HcpDialectTypes.h.inc"
  COMMAND ${MLIR_TBLGEN} --gen-typedef-decls -dialect hcp
    ${MLIR_TBLGEN_FLAGS}
    "${TD_DIR}/HcpDialect.td" -o "${GEN_DIR}/HcpDialectTypes.h.inc"
  DEPENDS "${TD_DIR}/HcpDialect.td"
  COMMENT "Generating HcpDialectTypes.h.inc"
)

# Aggregate target.
add_custom_target(VAKEDMLIRTablegen
  DEPENDS
    "${GEN_DIR}/VakedDialect.h.inc"
    "${GEN_DIR}/VakedDialect.cpp.inc"
    "${GEN_DIR}/VakedDialectOps.h.inc"
    "${GEN_DIR}/VakedDialectTypes.h.inc"
    "${GEN_DIR}/VakedDialectTypes.cpp.inc"
    "${GEN_DIR}/HcpDialect.h.inc"
    "${GEN_DIR}/HcpDialect.cpp.inc"
    "${GEN_DIR}/HcpDialectOps.h.inc"
    "${GEN_DIR}/HcpDialectTypes.h.inc"
    "${GEN_DIR}/HcpDialectTypes.cpp.inc"
)

# ---------------------------------------------------------------------------//
# Library
# ---------------------------------------------------------------------------//

set(VAKED_MLIR_SOURCES
  VakedDialect.cpp
  HcpDialect.cpp
)

add_library(VakedMLIRDialects STATIC ${VAKED_MLIR_SOURCES})
target_include_directories(VakedMLIRDialects PUBLIC
  "${MLIR_INCLUDE_DIRS}"
  "${LLVM_INCLUDE_DIR}"
  "${LLVM_BINARY_DIR}/include"
  "${GEN_DIR}"
  "${TD_DIR}"
)
target_link_libraries(VakedMLIRDialects PUBLIC
  MLIRIR
  MLIRSupport
)

add_dependencies(VakedMLIRDialects VAKEDMLIRTablegen)

# ---------------------------------------------------------------------------//
# Install
# ---------------------------------------------------------------------------//

install(TARGETS VakedMLIRDialects
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
  LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
)
install(DIRECTORY ${GEN_DIR}/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
  FILES_MATCHING PATTERN "*.inc"
)
install(FILES
  ${TD_DIR}/VakedDialect.td ${TD_DIR}/HcpDialect.td
  DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
)

# ---------------------------------------------------------------------------//
# Tests
# ---------------------------------------------------------------------------//

add_custom_target(check-vaked-mlir
  COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/run_tests.sh
  DEPENDS VakedMLIRDialects
  COMMENT "Running vaked MLIR dialect tests"
)
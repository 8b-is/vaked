//===-- HcpDialect.cpp - HCP MLIR dialect implementation ------------------===//
//
// Implements the hcp dialect: low-level orchestration mechanics.
// Spec: docs/language/0020-mlir-hcp-dialect.md
//
//===----------------------------------------------------------------------===//

#include "HcpDialect.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/DialectImplementation.h"
#include "mlir/IR/Verifier.h"

//===----------------------------------------------------------------------===//
// Op definitions (included ONCE at file scope).
//===----------------------------------------------------------------------===//

#define GET_OP_CLASSES
#include "HcpDialect.cpp.inc"

//===----------------------------------------------------------------------===//
// Dialect registration (uses filtered types-only inc to avoid duplicate).
//===----------------------------------------------------------------------===//

void vaked::mlir::hcp::HcpDialect::initialize() {
  addOperations<
    #define GET_OP_LIST
    #include "HcpDialect.cpp.inc"
  >();

  addTypes<
    #define GET_TYPEDEF_LIST
    #include "HcpDialectTypes.cpp.inc"
  >();
}

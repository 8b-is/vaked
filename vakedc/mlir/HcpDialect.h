//===-- HcpDialect.h - HCP MLIR dialect declarations -----------*- c++ -*-===//
//
// Defines the hcp dialect classes. The TableGen-generated .inc files
// provide most declarations; this header wraps them for compilation.
//
//===----------------------------------------------------------------------===//

#ifndef VAKED_HCPDIALECT_H
#define VAKED_HCPDIALECT_H

#include "mlir/IR/Dialect.h"
#include "mlir/IR/OpDefinition.h"
#include "mlir/IR/OpImplementation.h"

// Include the auto-generated dialect and type declarations.
#include "HcpDialect.h.inc"

// Forward-declare the dialect class.
namespace vaked::mlir::hcp {
class HcpDialect : public ::vaked::mlir::hcp::HcpDialectBase {
public:
  using HcpDialectBase::HcpDialectBase;
  void initialize() override;
};
} // namespace vaked::mlir::hcp

#endif // VAKED_HCPDIALECT_H

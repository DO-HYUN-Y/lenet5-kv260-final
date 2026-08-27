#pragma once

#include "alexnet_golden/tensor.hpp"

namespace alexnet::golden {

// Numeric model of an output-stationary packed SA tile. Activations are [M,K]
// and weights are logical [N,K]. Adjacent M lanes share one packed multiplier.
// The function intentionally ignores cycle latency; skew timing is modeled by
// LocalSkewRef and the SV transaction scoreboard.
MatrixI32 packed_os_matmul_tile(const MatrixI8& activations,
                                const MatrixI8& weights);

}  // namespace alexnet::golden

#pragma once

#include <cstdint>
#include <vector>

#include "alexnet_golden/quant_ref.hpp"
#include "alexnet_golden/tensor.hpp"

namespace alexnet::golden {

// Weight matrix is row-major [output_feature][input_feature].
MatrixI32 linear_accumulate(const MatrixI8& input,
                            const MatrixI8& weights);

MatrixI8 linear_requantize(const MatrixI32& accumulators,
                           const std::vector<RequantParams>& params);

MatrixI8 linear(const MatrixI8& input, const MatrixI8& weights,
                const std::vector<RequantParams>& params);

}  // namespace alexnet::golden

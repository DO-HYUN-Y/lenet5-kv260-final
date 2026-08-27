#include "alexnet_golden/linear_ref.hpp"

#include <limits>
#include <stdexcept>

namespace alexnet::golden {

MatrixI32 linear_accumulate(const MatrixI8& input,
                            const MatrixI8& weights) {
  if (input.cols() != weights.cols()) {
    throw std::invalid_argument("linear input K does not match weight K");
  }
  MatrixI32 output(input.rows(), weights.rows());
  for (int batch = 0; batch < input.rows(); ++batch) {
    for (int output_feature = 0; output_feature < weights.rows();
         ++output_feature) {
      std::int64_t accumulator = 0;
      for (int k = 0; k < input.cols(); ++k) {
        accumulator += static_cast<std::int32_t>(input.at(batch, k)) *
                       static_cast<std::int32_t>(weights.at(output_feature, k));
      }
      if (accumulator < std::numeric_limits<std::int32_t>::min() ||
          accumulator > std::numeric_limits<std::int32_t>::max()) {
        throw std::overflow_error("linear INT32 accumulator overflow");
      }
      output.at(batch, output_feature) = static_cast<std::int32_t>(accumulator);
    }
  }
  return output;
}

MatrixI8 linear_requantize(const MatrixI32& accumulators,
                           const std::vector<RequantParams>& params) {
  if (params.size() != 1 &&
      params.size() != static_cast<std::size_t>(accumulators.cols())) {
    throw std::invalid_argument("linear requant params must be per-layer or per-output");
  }
  MatrixI8 output(accumulators.rows(), accumulators.cols());
  for (int batch = 0; batch < output.rows(); ++batch) {
    for (int output_feature = 0; output_feature < output.cols(); ++output_feature) {
      output.at(batch, output_feature) = requantize(
          accumulators.at(batch, output_feature),
          channel_params(params, output_feature));
    }
  }
  return output;
}

MatrixI8 linear(const MatrixI8& input, const MatrixI8& weights,
                const std::vector<RequantParams>& params) {
  return linear_requantize(linear_accumulate(input, weights), params);
}

}  // namespace alexnet::golden

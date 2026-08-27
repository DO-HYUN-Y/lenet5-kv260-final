#pragma once

#include <cstdint>
#include <vector>

#include "alexnet_golden/quant_ref.hpp"
#include "alexnet_golden/tensor.hpp"
#include "alexnet_golden/window_ref.hpp"

namespace alexnet::golden {

// Logical OIHW tensor. The I dimension is input channels per group.
struct ConvWeightsI8 {
  int output_channels = 0;
  int input_channels_per_group = 0;
  int kernel_h = 0;
  int kernel_w = 0;
  std::vector<std::int8_t> values;

  std::int8_t at(int output_channel, int input_channel_in_group,
                 int kernel_y, int kernel_x) const;
  void validate() const;
};

struct Conv2DConfig {
  ConvGeometry geometry;
  int groups = 1;
};

TensorI32 conv2d_accumulate(const TensorI8& input,
                            const ConvWeightsI8& weights,
                            const Conv2DConfig& config);

TensorI8 conv2d_requantize(const TensorI32& accumulators,
                           const std::vector<RequantParams>& params);

TensorI8 conv2d(const TensorI8& input, const ConvWeightsI8& weights,
                const Conv2DConfig& config,
                const std::vector<RequantParams>& params);

}  // namespace alexnet::golden

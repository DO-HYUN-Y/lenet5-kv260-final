#pragma once

#include <cstdint>
#include <vector>

#include "alexnet_golden/tensor.hpp"

namespace alexnet::golden {

struct ConvGeometry {
  int kernel_h = 1;
  int kernel_w = 1;
  int stride_h = 1;
  int stride_w = 1;
  int pad_h = 0;
  int pad_w = 0;
  int dilation_h = 1;
  int dilation_w = 1;
};

struct WindowToken {
  int k = 0;
  int kernel_y = 0;
  int kernel_x = 0;
  int input_channel = 0;
  std::vector<std::int8_t> activations;
  std::vector<std::uint8_t> lane_valid;
  bool reduce_last = false;
};

int conv_output_dim(int input, int kernel, int stride, int padding,
                    int dilation = 1);
int conv_k_depth(int input_channels_per_group, const ConvGeometry& geometry);

// Generates the physical K-major source stream used by the SA:
//   k = ((kernel_y * kernel_w) + kernel_x) * Cin_per_group + input_channel.
// Spatial lanes are linear output positions starting at output_position_base.
std::vector<WindowToken> make_window_tokens(
    const TensorI8& input, int batch, int input_channel_base,
    int input_channels_per_group, const ConvGeometry& geometry,
    int output_position_base, int lane_count);

}  // namespace alexnet::golden

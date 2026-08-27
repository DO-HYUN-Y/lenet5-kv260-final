#include "alexnet_golden/dpi_wrappers.h"

#include <algorithm>
#include <initializer_list>
#include <limits>
#include <stdexcept>
#include <vector>

#include "alexnet_golden/conv2d_ref.hpp"
#include "alexnet_golden/linear_ref.hpp"
#include "alexnet_golden/maxpool_ref.hpp"
#include "alexnet_golden/packed_mac_ref.hpp"
#include "alexnet_golden/quant_ref.hpp"
#include "alexnet_golden/sa_tile_ref.hpp"

namespace {

std::size_t element_count(std::initializer_list<int> dimensions) {
  std::size_t count = 1;
  for (const int dimension : dimensions) {
    if (dimension <= 0 ||
        count > std::numeric_limits<std::size_t>::max() /
                    static_cast<std::size_t>(dimension)) {
      throw std::invalid_argument("invalid C ABI tensor dimensions");
    }
    count *= static_cast<std::size_t>(dimension);
  }
  return count;
}

template <typename T>
std::vector<T> copy_elements(const T* source, std::size_t count) {
  return std::vector<T>(source, source + count);
}

}  // namespace

extern "C" int alexnet_golden_packed_products(
    int8_t act_lo, int8_t act_hi, int8_t weight, int32_t* product_lo,
    int32_t* product_hi) {
  if (product_lo == nullptr || product_hi == nullptr) {
    return -1;
  }
  try {
    const auto result =
        alexnet::golden::packed_products(act_lo, act_hi, weight);
    *product_lo = result.lo;
    *product_hi = result.hi;
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_requantize(
    int32_t accumulator, int32_t bias, int32_t multiplier,
    uint8_t right_shift, uint8_t relu, int8_t* output) {
  if (output == nullptr) {
    return -1;
  }
  try {
    *output = alexnet::golden::requantize(
        accumulator,
        alexnet::golden::RequantParams{bias, multiplier, right_shift, relu != 0});
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_linear_point(const int8_t* input,
                                             const int8_t* weights,
                                             int k_depth,
                                             int32_t* accumulator) {
  if (input == nullptr || weights == nullptr || accumulator == nullptr ||
      k_depth <= 0) {
    return -1;
  }
  try {
    int64_t sum = 0;
    for (int k = 0; k < k_depth; ++k) {
      sum += static_cast<int32_t>(input[k]) * static_cast<int32_t>(weights[k]);
    }
    if (sum < std::numeric_limits<int32_t>::min() ||
        sum > std::numeric_limits<int32_t>::max()) {
      return -3;
    }
    *accumulator = static_cast<int32_t>(sum);
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_maxpool_point(
    const int8_t* input, int input_h, int input_w, int origin_y, int origin_x,
    int kernel_h, int kernel_w, int8_t* output) {
  if (input == nullptr || output == nullptr || input_h <= 0 || input_w <= 0 ||
      kernel_h <= 0 || kernel_w <= 0) {
    return -1;
  }
  bool saw_input = false;
  int8_t maximum = std::numeric_limits<int8_t>::min();
  for (int ky = 0; ky < kernel_h; ++ky) {
    const int y = origin_y + ky;
    for (int kx = 0; kx < kernel_w; ++kx) {
      const int x = origin_x + kx;
      if (y < 0 || y >= input_h || x < 0 || x >= input_w) {
        continue;
      }
      maximum = std::max(maximum, input[y * input_w + x]);
      saw_input = true;
    }
  }
  if (!saw_input) {
    return -2;
  }
  *output = maximum;
  return 0;
}

extern "C" int alexnet_golden_conv2d_accumulate(
    const int8_t* input, int batch, int input_channels, int input_h,
    int input_w, const int8_t* weights, int output_channels,
    int input_channels_per_group, int kernel_h, int kernel_w, int groups,
    int stride_h, int stride_w, int pad_h, int pad_w, int dilation_h,
    int dilation_w, int32_t* output, int output_count) {
  if (input == nullptr || weights == nullptr || output == nullptr ||
      output_count <= 0) {
    return -1;
  }
  try {
    const std::size_t input_count =
        element_count({batch, input_channels, input_h, input_w});
    const std::size_t weight_count = element_count(
        {output_channels, input_channels_per_group, kernel_h, kernel_w});
    alexnet::golden::TensorI8 input_tensor(
        batch, input_channels, input_h, input_w,
        copy_elements(input, input_count));
    alexnet::golden::ConvWeightsI8 weight_tensor{
        output_channels, input_channels_per_group, kernel_h, kernel_w,
        copy_elements(weights, weight_count)};
    const alexnet::golden::ConvGeometry geometry{
        kernel_h, kernel_w, stride_h, stride_w, pad_h, pad_w, dilation_h,
        dilation_w};
    const auto result = alexnet::golden::conv2d_accumulate(
        input_tensor, weight_tensor, {geometry, groups});
    if (result.size() != static_cast<std::size_t>(output_count)) {
      return -3;
    }
    std::copy(result.data().begin(), result.data().end(), output);
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_linear_accumulate(
    const int8_t* input, int m_count, int k_depth, const int8_t* weights,
    int n_count, int32_t* output, int output_count) {
  if (input == nullptr || weights == nullptr || output == nullptr ||
      output_count <= 0) {
    return -1;
  }
  try {
    alexnet::golden::MatrixI8 input_matrix(
        m_count, k_depth,
        copy_elements(input, element_count({m_count, k_depth})));
    alexnet::golden::MatrixI8 weight_matrix(
        n_count, k_depth,
        copy_elements(weights, element_count({n_count, k_depth})));
    const auto result =
        alexnet::golden::linear_accumulate(input_matrix, weight_matrix);
    if (result.size() != static_cast<std::size_t>(output_count)) {
      return -3;
    }
    std::copy(result.data().begin(), result.data().end(), output);
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_maxpool2d(
    const int8_t* input, int batch, int channels, int input_h, int input_w,
    int kernel_h, int kernel_w, int stride_h, int stride_w, int pad_h,
    int pad_w, int8_t* output, int output_count) {
  if (input == nullptr || output == nullptr || output_count <= 0) {
    return -1;
  }
  try {
    alexnet::golden::TensorI8 input_tensor(
        batch, channels, input_h, input_w,
        copy_elements(input,
                      element_count({batch, channels, input_h, input_w})));
    const auto result = alexnet::golden::maxpool2d(
        input_tensor,
        {kernel_h, kernel_w, stride_h, stride_w, pad_h, pad_w});
    if (result.size() != static_cast<std::size_t>(output_count)) {
      return -3;
    }
    std::copy(result.data().begin(), result.data().end(), output);
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_packed_os_matmul(
    const int8_t* activations, int m_count, int k_depth,
    const int8_t* weights, int n_count, int32_t* output, int output_count) {
  if (activations == nullptr || weights == nullptr || output == nullptr ||
      output_count <= 0) {
    return -1;
  }
  try {
    alexnet::golden::MatrixI8 activation_matrix(
        m_count, k_depth,
        copy_elements(activations, element_count({m_count, k_depth})));
    alexnet::golden::MatrixI8 weight_matrix(
        n_count, k_depth,
        copy_elements(weights, element_count({n_count, k_depth})));
    const auto result = alexnet::golden::packed_os_matmul_tile(
        activation_matrix, weight_matrix);
    if (result.size() != static_cast<std::size_t>(output_count)) {
      return -3;
    }
    std::copy(result.data().begin(), result.data().end(), output);
    return 0;
  } catch (...) {
    return -2;
  }
}

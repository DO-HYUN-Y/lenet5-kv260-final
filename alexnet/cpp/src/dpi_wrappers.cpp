#include "alexnet_golden/dpi_wrappers.h"

#include <algorithm>
#include <limits>

#include "alexnet_golden/packed_mac_ref.hpp"
#include "alexnet_golden/quant_ref.hpp"

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

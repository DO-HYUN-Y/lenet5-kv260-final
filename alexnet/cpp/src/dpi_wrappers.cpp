#include "alexnet_golden/dpi_wrappers.h"

#include <algorithm>
#include <initializer_list>
#include <limits>
#include <memory>
#include <stdexcept>
#include <utility>
#include <vector>

#include "alexnet_golden/activation_bank_ref.hpp"
#include "alexnet_golden/activation_pingpong_ref.hpp"
#include "alexnet_golden/conv2d_ref.hpp"
#include "alexnet_golden/linear_ref.hpp"
#include "alexnet_golden/layout_ref.hpp"
#include "alexnet_golden/maxpool_ref.hpp"
#include "alexnet_golden/output_router_ref.hpp"
#include "alexnet_golden/packed_mac_ref.hpp"
#include "alexnet_golden/partial_sum_bank_ref.hpp"
#include "alexnet_golden/quant_ref.hpp"
#include "alexnet_golden/sa_tile_ref.hpp"
#include "alexnet_golden/window_ref.hpp"
#include "alexnet_golden/weight_tile_bank_ref.hpp"

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

std::vector<alexnet::golden::RequantParams> copy_requant_params(
    int channel_count, const int32_t* bias, const int32_t* multiplier,
    const uint8_t* right_shift, bool relu) {
  if (bias == nullptr || multiplier == nullptr || right_shift == nullptr) {
    throw std::invalid_argument("null C ABI requant parameter array");
  }
  std::vector<alexnet::golden::RequantParams> params;
  params.reserve(static_cast<std::size_t>(channel_count));
  for (int channel = 0; channel < channel_count; ++channel) {
    params.push_back(alexnet::golden::RequantParams{
        bias[channel], multiplier[channel], right_shift[channel], relu});
  }
  return params;
}

std::unique_ptr<alexnet::golden::PostprocessScannerRef> g_scanner;
std::unique_ptr<alexnet::golden::N8OutputRouterRef> g_router;
std::unique_ptr<alexnet::golden::N8ActivationBankRef> g_activation_bank;
std::unique_ptr<alexnet::golden::N8ActivationPingPongRef>
    g_activation_pingpong;
std::unique_ptr<alexnet::golden::N8ActivationDualSegmentPingPongRef>
    g_activation_dual_segment_pingpong;
std::unique_ptr<alexnet::golden::N8WeightTileBankRef> g_weight_tile_bank;
std::unique_ptr<alexnet::golden::N8Int32PartialSumBankRef> g_partial_sum_bank;

struct WindowM4State {
  alexnet::golden::TensorI8 input;
  alexnet::golden::ConvGeometry geometry;
  int channel_count = 0;
  int output_w = 0;
  int cached_output_y = -1;
  int cached_output_x = -1;
  int cached_m_count = 0;
  std::vector<alexnet::golden::WindowToken> cached_tokens;
};

std::unique_ptr<WindowM4State> g_window_m4;

std::array<std::int8_t, 8> unpack_router_values(std::uint64_t packed) {
  std::array<std::int8_t, 8> values{};
  for (int lane = 0; lane < 8; ++lane) {
    values[static_cast<std::size_t>(lane)] = static_cast<std::int8_t>(
        (packed >> (lane * 8)) & std::uint64_t{0xff});
  }
  return values;
}

std::uint64_t pack_router_values(const std::array<std::int8_t, 8>& values) {
  std::uint64_t packed = 0;
  for (int lane = 0; lane < 8; ++lane) {
    packed |= static_cast<std::uint64_t>(
                  static_cast<std::uint8_t>(values[static_cast<std::size_t>(lane)]))
              << (lane * 8);
  }
  return packed;
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

extern "C" int alexnet_golden_maxpool3x3_n8(
    uint64_t p00, uint64_t p01, uint64_t p02,
    uint64_t p10, uint64_t p11, uint64_t p12,
    uint64_t p20, uint64_t p21, uint64_t p22,
    uint8_t lane_mask, uint64_t* output) {
  if (output == nullptr) {
    return -1;
  }
  try {
    const uint64_t pixels[3][3] = {
        {p00, p01, p02}, {p10, p11, p12}, {p20, p21, p22}};
    std::vector<int8_t> nchw(8 * 3 * 3);
    for (int lane = 0; lane < 8; ++lane) {
      for (int y = 0; y < 3; ++y) {
        for (int x = 0; x < 3; ++x) {
          const auto byte_value = static_cast<uint8_t>(
              (pixels[y][x] >> (lane * 8)) & UINT64_C(0xff));
          nchw[static_cast<std::size_t>(lane * 9 + y * 3 + x)] =
              static_cast<int8_t>(byte_value);
        }
      }
    }
    const alexnet::golden::TensorI8 input_tensor(1, 8, 3, 3,
                                                  std::move(nchw));
    const auto pooled = alexnet::golden::maxpool2d(
        input_tensor, {3, 3, 2, 2, 0, 0});
    uint64_t packed = 0;
    for (int lane = 0; lane < 8; ++lane) {
      if ((lane_mask & (UINT8_C(1) << lane)) != 0) {
        packed |= static_cast<uint64_t>(
                      static_cast<uint8_t>(pooled.at(0, lane, 0, 0)))
                  << (lane * 8);
      }
    }
    *output = packed;
    return 0;
  } catch (...) {
    return -2;
  }
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

extern "C" int alexnet_golden_conv2d_int8(
    const int8_t* input, int batch, int input_channels, int input_h,
    int input_w, const int8_t* weights, int output_channels,
    int input_channels_per_group, int kernel_h, int kernel_w, int groups,
    int stride_h, int stride_w, int pad_h, int pad_w, int dilation_h,
    int dilation_w, const int32_t* bias, const int32_t* multiplier,
    const uint8_t* right_shift, uint8_t relu, int8_t* output,
    int output_count) {
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
    const auto result = alexnet::golden::conv2d(
        input_tensor, weight_tensor, {geometry, groups},
        copy_requant_params(output_channels, bias, multiplier, right_shift,
                            relu != 0));
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

extern "C" int alexnet_golden_linear_int8(
    const int8_t* input, int m_count, int k_depth, const int8_t* weights,
    int n_count, const int32_t* bias, const int32_t* multiplier,
    const uint8_t* right_shift, uint8_t relu, int8_t* output,
    int output_count) {
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
    const auto result = alexnet::golden::linear(
        input_matrix, weight_matrix,
        copy_requant_params(n_count, bias, multiplier, right_shift,
                            relu != 0));
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

extern "C" int alexnet_golden_scanner_reset(int m_count, int n_count,
                                               int n_base) {
  try {
    g_scanner = std::make_unique<alexnet::golden::PostprocessScannerRef>(
        m_count, n_count, 8, n_base);
    return 0;
  } catch (...) {
    g_scanner.reset();
    return -2;
  }
}

extern "C" int alexnet_golden_scanner_tick(uint8_t ready, uint8_t* valid,
                                              int32_t* m,
                                              uint8_t* n_lane_mask) {
  if (!g_scanner || valid == nullptr || m == nullptr || n_lane_mask == nullptr) {
    return -1;
  }
  try {
    const auto cycle = g_scanner->tick(ready != 0);
    if (!cycle.has_value()) {
      *valid = 0;
      *m = 0;
      *n_lane_mask = 0;
      return 0;
    }
    *valid = 1;
    *m = cycle->front().m;
    *n_lane_mask = static_cast<uint8_t>(
        (std::uint16_t{1} << cycle->size()) - std::uint16_t{1});
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_router_reset(int slice, int fifo_depth) {
  try {
    g_router = std::make_unique<alexnet::golden::N8OutputRouterRef>(
        slice, static_cast<std::size_t>(fifo_depth));
    return 0;
  } catch (...) {
    g_router.reset();
    return -2;
  }
}

extern "C" int alexnet_golden_router_configure(uint8_t destination,
                                                  int32_t n64_tile_base) {
  if (!g_router) {
    return -1;
  }
  try {
    g_router->configure(
        static_cast<alexnet::golden::OutputDestination>(destination),
        n64_tile_base);
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_router_tick(
    uint8_t ingress_valid, int32_t ingress_m, int32_t ingress_tile_tag,
    uint8_t ingress_lane_mask, uint64_t ingress_values,
    uint8_t egress_ready, uint8_t* ingress_ready, uint8_t* egress_valid,
    uint8_t* egress_destination, int32_t* egress_slice, int32_t* egress_m,
    int32_t* egress_n_base, int32_t* egress_tile_tag,
    uint8_t* egress_lane_mask, uint64_t* egress_values) {
  if (!g_router || ingress_ready == nullptr || egress_valid == nullptr ||
      egress_destination == nullptr || egress_slice == nullptr ||
      egress_m == nullptr || egress_n_base == nullptr ||
      egress_tile_tag == nullptr || egress_lane_mask == nullptr ||
      egress_values == nullptr) {
    return -1;
  }
  try {
    const alexnet::golden::OutputRouterIngress ingress{
        ingress_m, ingress_tile_tag, ingress_lane_mask,
        unpack_router_values(ingress_values)};
    const auto cycle = g_router->tick(ingress_valid != 0, ingress,
                                      egress_ready != 0);
    *ingress_ready = cycle.ingress_ready ? 1 : 0;
    *egress_valid = cycle.egress.has_value() ? 1 : 0;
    *egress_destination = 0;
    *egress_slice = 0;
    *egress_m = 0;
    *egress_n_base = 0;
    *egress_tile_tag = 0;
    *egress_lane_mask = 0;
    *egress_values = 0;
    if (cycle.egress.has_value()) {
      *egress_destination = static_cast<uint8_t>(cycle.egress->destination);
      *egress_slice = cycle.egress->slice;
      *egress_m = cycle.egress->m;
      *egress_n_base = cycle.egress->n_base;
      *egress_tile_tag = cycle.egress->tile_tag;
      *egress_lane_mask = cycle.egress->lane_mask;
      *egress_values = pack_router_values(cycle.egress->values);
    }
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_router_queued(int32_t* queued_packets) {
  if (!g_router || queued_packets == nullptr) {
    return -1;
  }
  if (g_router->queued_packets() >
      static_cast<std::size_t>(std::numeric_limits<int32_t>::max())) {
    return -2;
  }
  *queued_packets = static_cast<int32_t>(g_router->queued_packets());
  return 0;
}

extern "C" int alexnet_golden_activation_bank_reset(int depth) {
  try {
    g_activation_bank =
        std::make_unique<alexnet::golden::N8ActivationBankRef>(depth);
    return 0;
  } catch (...) {
    g_activation_bank.reset();
    return -2;
  }
}

extern "C" int alexnet_golden_activation_bank_begin_fill(
    int word_count, uint8_t lane_mask, int tensor_tag) {
  if (!g_activation_bank || word_count <= 0) {
    return -1;
  }
  try {
    g_activation_bank->begin_fill(static_cast<std::size_t>(word_count),
                                  lane_mask, tensor_tag);
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_activation_bank_write(
    uint64_t values, uint8_t lane_mask, uint8_t last) {
  if (!g_activation_bank) {
    return -1;
  }
  try {
    g_activation_bank->write(values, lane_mask, last != 0);
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_activation_bank_begin_read(void) {
  if (!g_activation_bank) {
    return -1;
  }
  try {
    g_activation_bank->begin_read();
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_activation_bank_word(
    int index, uint64_t* values, uint8_t* lane_mask, uint8_t* last,
    int* tensor_tag) {
  if (!g_activation_bank || index < 0 || values == nullptr ||
      lane_mask == nullptr || last == nullptr || tensor_tag == nullptr) {
    return -1;
  }
  try {
    const auto word =
        g_activation_bank->word(static_cast<std::size_t>(index));
    *values = pack_router_values(word.values);
    *lane_mask = word.lane_mask;
    *last = word.last ? 1 : 0;
    *tensor_tag = word.tensor_tag;
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_activation_bank_complete_read(void) {
  if (!g_activation_bank) {
    return -1;
  }
  try {
    g_activation_bank->complete_read();
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_activation_bank_state(
    uint8_t* state, int* words_written) {
  if (!g_activation_bank || state == nullptr || words_written == nullptr) {
    return -1;
  }
  *state = static_cast<uint8_t>(g_activation_bank->state());
  *words_written = static_cast<int>(g_activation_bank->words_written());
  return 0;
}

extern "C" int alexnet_golden_activation_pingpong_reset(int depth) {
  if (depth <= 0) {
    return -1;
  }
  try {
    g_activation_pingpong =
        std::make_unique<alexnet::golden::N8ActivationPingPongRef>(depth);
    return 0;
  } catch (...) {
    g_activation_pingpong.reset();
    return -2;
  }
}

extern "C" int alexnet_golden_activation_pingpong_begin_fill(
    uint8_t is_pooled, int word_count, uint8_t lane_mask, int tensor_tag,
    uint8_t* bank) {
  if (!g_activation_pingpong || is_pooled > 1 || word_count <= 0 ||
      bank == nullptr) {
    return -1;
  }
  try {
    *bank = static_cast<uint8_t>(g_activation_pingpong->begin_fill(
        is_pooled != 0, static_cast<std::size_t>(word_count), lane_mask,
        tensor_tag));
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_activation_pingpong_write(
    uint8_t is_pooled, uint64_t values, uint8_t lane_mask, uint8_t last) {
  if (!g_activation_pingpong || is_pooled > 1) {
    return -1;
  }
  try {
    g_activation_pingpong->write(is_pooled != 0, values, lane_mask,
                                 last != 0);
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_activation_pingpong_begin_read(
    int tensor_tag, uint8_t* bank) {
  if (!g_activation_pingpong || bank == nullptr) {
    return -1;
  }
  try {
    *bank = static_cast<uint8_t>(
        g_activation_pingpong->begin_read(tensor_tag));
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_activation_pingpong_word(
    int index, uint64_t* values, uint8_t* lane_mask, uint8_t* last,
    int* tensor_tag) {
  if (!g_activation_pingpong || index < 0 || values == nullptr ||
      lane_mask == nullptr || last == nullptr || tensor_tag == nullptr) {
    return -1;
  }
  try {
    const auto word =
        g_activation_pingpong->word(static_cast<std::size_t>(index));
    *values = pack_router_values(word.values);
    *lane_mask = word.lane_mask;
    *last = word.last ? 1 : 0;
    *tensor_tag = word.tensor_tag;
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_activation_pingpong_complete_read(void) {
  if (!g_activation_pingpong) {
    return -1;
  }
  try {
    g_activation_pingpong->complete_read();
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_activation_pingpong_state(
    uint8_t* bank0_state, int* bank0_words, uint8_t* bank1_state,
    int* bank1_words, int* ready_count, uint8_t* ready_valid,
    uint8_t* ready_bank, int* ready_tag, uint8_t* fill_active,
    uint8_t* fill_bank, uint8_t* fill_is_pooled, uint8_t* read_active,
    uint8_t* read_bank) {
  if (!g_activation_pingpong || bank0_state == nullptr ||
      bank0_words == nullptr || bank1_state == nullptr ||
      bank1_words == nullptr || ready_count == nullptr ||
      ready_valid == nullptr || ready_bank == nullptr ||
      ready_tag == nullptr || fill_active == nullptr ||
      fill_bank == nullptr || fill_is_pooled == nullptr ||
      read_active == nullptr || read_bank == nullptr) {
    return -1;
  }
  try {
    const auto& bank0 = g_activation_pingpong->bank(0);
    const auto& bank1 = g_activation_pingpong->bank(1);
    *bank0_state = static_cast<uint8_t>(bank0.state());
    *bank0_words = static_cast<int>(bank0.words_written());
    *bank1_state = static_cast<uint8_t>(bank1.state());
    *bank1_words = static_cast<int>(bank1.words_written());
    *ready_count = static_cast<int>(g_activation_pingpong->ready_count());
    *ready_valid = g_activation_pingpong->ready_count() != 0 ? 1 : 0;
    *ready_bank = static_cast<uint8_t>(
        g_activation_pingpong->ready_head_bank() < 0
            ? 0
            : g_activation_pingpong->ready_head_bank());
    *ready_tag = g_activation_pingpong->ready_head_tag();
    *fill_active = g_activation_pingpong->fill_bank() >= 0 ? 1 : 0;
    *fill_bank = static_cast<uint8_t>(
        g_activation_pingpong->fill_bank() < 0
            ? 0
            : g_activation_pingpong->fill_bank());
    *fill_is_pooled = g_activation_pingpong->fill_is_pooled() ? 1 : 0;
    *read_active = g_activation_pingpong->read_bank() >= 0 ? 1 : 0;
    *read_bank = static_cast<uint8_t>(
        g_activation_pingpong->read_bank() < 0
            ? 0
            : g_activation_pingpong->read_bank());
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_activation_dual_segment_pingpong_reset(
    int segment_depth) {
  if (segment_depth <= 0) {
    return -1;
  }
  try {
    g_activation_dual_segment_pingpong = std::make_unique<
        alexnet::golden::N8ActivationDualSegmentPingPongRef>(segment_depth);
    return 0;
  } catch (...) {
    g_activation_dual_segment_pingpong.reset();
    return -2;
  }
}

extern "C" int alexnet_golden_activation_dual_segment_pingpong_begin_fill(
    uint8_t is_pooled, int word_count, uint8_t lane_mask, int tensor_tag,
    uint8_t* bank) {
  if (!g_activation_dual_segment_pingpong || is_pooled > 1 ||
      word_count <= 0 || bank == nullptr) {
    return -1;
  }
  try {
    *bank = static_cast<uint8_t>(
        g_activation_dual_segment_pingpong->begin_fill(
            is_pooled != 0, static_cast<std::size_t>(word_count), lane_mask,
            tensor_tag));
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_activation_dual_segment_pingpong_write(
    uint8_t is_pooled, uint64_t values, uint8_t lane_mask, uint8_t last) {
  if (!g_activation_dual_segment_pingpong || is_pooled > 1) {
    return -1;
  }
  try {
    g_activation_dual_segment_pingpong->write(
        is_pooled != 0, values, lane_mask, last != 0);
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_activation_dual_segment_pingpong_begin_read(
    int tensor_tag, uint8_t* bank) {
  if (!g_activation_dual_segment_pingpong || bank == nullptr) {
    return -1;
  }
  try {
    *bank = static_cast<uint8_t>(
        g_activation_dual_segment_pingpong->begin_read(tensor_tag));
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_activation_dual_segment_pingpong_word(
    int global_index, uint64_t* values, uint8_t* lane_mask, uint8_t* last,
    int* tensor_tag) {
  if (!g_activation_dual_segment_pingpong || global_index < 0 ||
      values == nullptr || lane_mask == nullptr || last == nullptr ||
      tensor_tag == nullptr) {
    return -1;
  }
  try {
    const auto word = g_activation_dual_segment_pingpong->word(
        static_cast<std::size_t>(global_index));
    *values = pack_router_values(word.values);
    *lane_mask = word.lane_mask;
    *last = word.last ? 1 : 0;
    *tensor_tag = word.tensor_tag;
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int
alexnet_golden_activation_dual_segment_pingpong_complete_segment0(void) {
  if (!g_activation_dual_segment_pingpong) {
    return -1;
  }
  try {
    g_activation_dual_segment_pingpong->complete_segment0_read();
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int
alexnet_golden_activation_dual_segment_pingpong_complete_read(void) {
  if (!g_activation_dual_segment_pingpong) {
    return -1;
  }
  try {
    g_activation_dual_segment_pingpong->complete_read();
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_activation_dual_segment_pingpong_state(
    int* ready_count, uint8_t* ready_valid, uint8_t* ready_bank,
    int* ready_tag, uint8_t* fill_active, uint8_t* fill_bank,
    uint8_t* fill_is_pooled, uint8_t* read_active, uint8_t* read_bank,
    uint8_t* read_segment) {
  if (!g_activation_dual_segment_pingpong || ready_count == nullptr ||
      ready_valid == nullptr || ready_bank == nullptr ||
      ready_tag == nullptr || fill_active == nullptr ||
      fill_bank == nullptr || fill_is_pooled == nullptr ||
      read_active == nullptr || read_bank == nullptr ||
      read_segment == nullptr) {
    return -1;
  }
  try {
    *ready_count = static_cast<int>(
        g_activation_dual_segment_pingpong->ready_count());
    *ready_valid = *ready_count != 0 ? 1 : 0;
    *ready_bank = static_cast<uint8_t>(
        *ready_valid ?
            g_activation_dual_segment_pingpong->ready_head_bank() : 0);
    *ready_tag = g_activation_dual_segment_pingpong->ready_head_tag();
    *fill_active =
        g_activation_dual_segment_pingpong->fill_bank() >= 0 ? 1 : 0;
    *fill_bank = static_cast<uint8_t>(
        *fill_active ? g_activation_dual_segment_pingpong->fill_bank() : 0);
    *fill_is_pooled =
        g_activation_dual_segment_pingpong->fill_is_pooled() ? 1 : 0;
    *read_active =
        g_activation_dual_segment_pingpong->read_bank() >= 0 ? 1 : 0;
    *read_bank = static_cast<uint8_t>(
        *read_active ? g_activation_dual_segment_pingpong->read_bank() : 0);
    *read_segment = static_cast<uint8_t>(
        *read_active ? g_activation_dual_segment_pingpong->read_segment() : 0);
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_weight_tile_bank_reset(int depth) {
  try {
    g_weight_tile_bank =
        std::make_unique<alexnet::golden::N8WeightTileBankRef>(depth);
    return 0;
  } catch (...) {
    g_weight_tile_bank.reset();
    return -2;
  }
}

extern "C" int alexnet_golden_weight_tile_bank_begin_fill(
    int k_count, uint8_t n_lane_mask, int context_tag) {
  if (!g_weight_tile_bank || k_count <= 0) {
    return -1;
  }
  try {
    g_weight_tile_bank->begin_fill(static_cast<std::size_t>(k_count),
                                   n_lane_mask, context_tag);
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_weight_tile_bank_write(
    uint64_t values, uint8_t n_lane_mask, uint8_t last) {
  if (!g_weight_tile_bank) {
    return -1;
  }
  try {
    g_weight_tile_bank->write(values, n_lane_mask, last != 0);
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_weight_tile_bank_begin_replay(
    int k_count, uint8_t n_lane_mask, int context_tag) {
  if (!g_weight_tile_bank || k_count <= 0) {
    return -1;
  }
  try {
    g_weight_tile_bank->begin_replay(static_cast<std::size_t>(k_count),
                                     n_lane_mask, context_tag);
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_weight_tile_bank_word(
    int k, uint64_t* values, uint8_t* n_lane_mask, uint8_t* last,
    int* context_tag) {
  if (!g_weight_tile_bank || k < 0 || values == nullptr ||
      n_lane_mask == nullptr || last == nullptr || context_tag == nullptr) {
    return -1;
  }
  try {
    const auto word =
        g_weight_tile_bank->word(static_cast<std::size_t>(k));
    *values = pack_router_values(word.values);
    *n_lane_mask = word.n_lane_mask;
    *last = word.last ? 1 : 0;
    *context_tag = word.context_tag;
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_weight_tile_bank_complete_replay(void) {
  if (!g_weight_tile_bank) {
    return -1;
  }
  try {
    g_weight_tile_bank->complete_replay();
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_weight_tile_bank_release(void) {
  if (!g_weight_tile_bank) {
    return -1;
  }
  try {
    g_weight_tile_bank->release();
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_weight_tile_bank_state(
    uint8_t* state, int* words_written, int* completed_replays) {
  if (!g_weight_tile_bank || state == nullptr || words_written == nullptr ||
      completed_replays == nullptr) {
    return -1;
  }
  *state = static_cast<uint8_t>(g_weight_tile_bank->state());
  *words_written = static_cast<int>(g_weight_tile_bank->words_written());
  *completed_replays =
      static_cast<int>(g_weight_tile_bank->completed_replays());
  return 0;
}

extern "C" int alexnet_golden_partial_sum_bank_reset(int depth) {
  try {
    g_partial_sum_bank =
        std::make_unique<alexnet::golden::N8Int32PartialSumBankRef>(depth);
    return 0;
  } catch (...) {
    g_partial_sum_bank.reset();
    return -2;
  }
}

extern "C" int alexnet_golden_partial_sum_bank_begin_chunk(
    int word_count, uint8_t n_lane_mask, int context_tag, int chunk_index,
    uint8_t first_chunk, uint8_t final_chunk) {
  if (!g_partial_sum_bank || word_count <= 0 || chunk_index < 0) {
    return -1;
  }
  try {
    g_partial_sum_bank->begin_chunk(
        static_cast<std::size_t>(word_count), n_lane_mask, context_tag,
        static_cast<std::size_t>(chunk_index), first_chunk != 0,
        final_chunk != 0);
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_partial_sum_bank_write(
    int index, int32_t accumulator0, int32_t accumulator1,
    int32_t accumulator2, int32_t accumulator3, int32_t accumulator4,
    int32_t accumulator5, int32_t accumulator6, int32_t accumulator7,
    uint8_t n_lane_mask, uint8_t last) {
  if (!g_partial_sum_bank || index < 0) {
    return -1;
  }
  try {
    const std::array<std::int32_t, 8> accumulators = {
        accumulator0, accumulator1, accumulator2, accumulator3,
        accumulator4, accumulator5, accumulator6, accumulator7};
    g_partial_sum_bank->write(static_cast<std::size_t>(index), accumulators,
                              n_lane_mask, last != 0);
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_partial_sum_bank_word(
    int index, int32_t* accumulator0, int32_t* accumulator1,
    int32_t* accumulator2, int32_t* accumulator3, int32_t* accumulator4,
    int32_t* accumulator5, int32_t* accumulator6, int32_t* accumulator7,
    uint8_t* n_lane_mask, uint8_t* last, int* context_tag) {
  if (!g_partial_sum_bank || index < 0 || accumulator0 == nullptr ||
      accumulator1 == nullptr || accumulator2 == nullptr ||
      accumulator3 == nullptr || accumulator4 == nullptr ||
      accumulator5 == nullptr || accumulator6 == nullptr ||
      accumulator7 == nullptr || n_lane_mask == nullptr || last == nullptr ||
      context_tag == nullptr) {
    return -1;
  }
  try {
    const auto word =
        g_partial_sum_bank->word(static_cast<std::size_t>(index));
    *accumulator0 = word.accumulators[0];
    *accumulator1 = word.accumulators[1];
    *accumulator2 = word.accumulators[2];
    *accumulator3 = word.accumulators[3];
    *accumulator4 = word.accumulators[4];
    *accumulator5 = word.accumulators[5];
    *accumulator6 = word.accumulators[6];
    *accumulator7 = word.accumulators[7];
    *n_lane_mask = word.n_lane_mask;
    *last = word.last ? 1 : 0;
    *context_tag = word.context_tag;
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_partial_sum_bank_complete_emit(void) {
  if (!g_partial_sum_bank) {
    return -1;
  }
  try {
    g_partial_sum_bank->complete_emit();
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_partial_sum_bank_state(
    uint8_t* state, int* words_accepted, int* next_chunk_index,
    int* completed_chunks) {
  if (!g_partial_sum_bank || state == nullptr || words_accepted == nullptr ||
      next_chunk_index == nullptr || completed_chunks == nullptr) {
    return -1;
  }
  *state = static_cast<uint8_t>(g_partial_sum_bank->state());
  *words_accepted = static_cast<int>(g_partial_sum_bank->words_accepted());
  *next_chunk_index =
      static_cast<int>(g_partial_sum_bank->next_chunk_index());
  *completed_chunks =
      static_cast<int>(g_partial_sum_bank->completed_chunks());
  return 0;
}

extern "C" int alexnet_golden_window_m4_reset(
    int input_h, int input_w, int channel_count, int kernel, int stride,
    int padding) {
  if (input_h <= 0 || input_w <= 0 || channel_count <= 0 ||
      channel_count > 8) {
    return -1;
  }
  try {
    auto state = std::make_unique<WindowM4State>();
    state->input =
        alexnet::golden::TensorI8(1, channel_count, input_h, input_w);
    state->geometry = {kernel, kernel, stride, stride, padding, padding, 1, 1};
    state->channel_count = channel_count;
    state->output_w = alexnet::golden::conv_output_dim(
        input_w, kernel, stride, padding);
    (void)alexnet::golden::conv_output_dim(input_h, kernel, stride, padding);
    g_window_m4 = std::move(state);
    return 0;
  } catch (...) {
    g_window_m4.reset();
    return -2;
  }
}

extern "C" int alexnet_golden_window_m4_set_pixel(
    int y, int x, uint64_t values) {
  if (!g_window_m4) {
    return -1;
  }
  try {
    for (int channel = 0; channel < g_window_m4->channel_count; ++channel) {
      const auto byte_value = static_cast<std::uint8_t>(
          (values >> (channel * 8)) & UINT64_C(0xff));
      g_window_m4->input.at(0, channel, y, x) =
          static_cast<std::int8_t>(byte_value);
    }
    g_window_m4->cached_tokens.clear();
    g_window_m4->cached_output_y = -1;
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_window_m4_token(
    int output_y, int output_x_base, int m_count, int k_index,
    uint32_t* activations, uint8_t* m_lane_mask, uint8_t* tile_clear,
    uint8_t* reduce_last) {
  if (!g_window_m4 || activations == nullptr || m_lane_mask == nullptr ||
      tile_clear == nullptr || reduce_last == nullptr || output_y < 0 ||
      output_x_base < 0 || m_count <= 0 || m_count > 4 || k_index < 0) {
    return -1;
  }
  try {
    if (g_window_m4->cached_output_y != output_y ||
        g_window_m4->cached_output_x != output_x_base ||
        g_window_m4->cached_m_count != m_count) {
      g_window_m4->cached_tokens = alexnet::golden::make_window_tokens(
          g_window_m4->input, 0, 0, g_window_m4->channel_count,
          g_window_m4->geometry,
          output_y * g_window_m4->output_w + output_x_base, m_count);
      g_window_m4->cached_output_y = output_y;
      g_window_m4->cached_output_x = output_x_base;
      g_window_m4->cached_m_count = m_count;
    }
    if (k_index >= static_cast<int>(g_window_m4->cached_tokens.size())) {
      return -3;
    }
    const auto& token =
        g_window_m4->cached_tokens[static_cast<std::size_t>(k_index)];
    std::uint32_t packed = 0;
    std::uint8_t mask = 0;
    for (int lane = 0; lane < m_count; ++lane) {
      packed |= static_cast<std::uint32_t>(static_cast<std::uint8_t>(
                    token.activations[static_cast<std::size_t>(lane)]))
                << (lane * 8);
      if (token.lane_valid[static_cast<std::size_t>(lane)] != 0) {
        mask |= static_cast<std::uint8_t>(UINT8_C(1) << lane);
      }
    }
    *activations = packed;
    *m_lane_mask = mask;
    *tile_clear = token.k == 0 ? 1 : 0;
    *reduce_last = token.reduce_last ? 1 : 0;
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_window_m8_reset(
    int input_h, int input_w, int channel_count, int kernel, int stride,
    int padding) {
  return alexnet_golden_window_m4_reset(
      input_h, input_w, channel_count, kernel, stride, padding);
}

extern "C" int alexnet_golden_window_m8_set_pixel(
    int y, int x, uint64_t values) {
  return alexnet_golden_window_m4_set_pixel(y, x, values);
}

extern "C" int alexnet_golden_window_m8_token(
    int output_y, int output_x_base, int m_count, int k_index,
    uint64_t* activations, uint8_t* m_lane_mask, uint8_t* tile_clear,
    uint8_t* reduce_last) {
  if (!g_window_m4 || activations == nullptr || m_lane_mask == nullptr ||
      tile_clear == nullptr || reduce_last == nullptr || output_y < 0 ||
      output_x_base < 0 || m_count <= 0 || m_count > 8 || k_index < 0) {
    return -1;
  }
  try {
    if (g_window_m4->cached_output_y != output_y ||
        g_window_m4->cached_output_x != output_x_base ||
        g_window_m4->cached_m_count != m_count) {
      g_window_m4->cached_tokens = alexnet::golden::make_window_tokens(
          g_window_m4->input, 0, 0, g_window_m4->channel_count,
          g_window_m4->geometry,
          output_y * g_window_m4->output_w + output_x_base, m_count);
      g_window_m4->cached_output_y = output_y;
      g_window_m4->cached_output_x = output_x_base;
      g_window_m4->cached_m_count = m_count;
    }
    if (k_index >= static_cast<int>(g_window_m4->cached_tokens.size())) {
      return -3;
    }
    const auto& token =
        g_window_m4->cached_tokens[static_cast<std::size_t>(k_index)];
    std::uint64_t packed = 0;
    std::uint8_t mask = 0;
    for (int lane = 0; lane < m_count; ++lane) {
      packed |= static_cast<std::uint64_t>(static_cast<std::uint8_t>(
                    token.activations[static_cast<std::size_t>(lane)]))
                << (lane * 8);
      if (token.lane_valid[static_cast<std::size_t>(lane)] != 0) {
        mask |= static_cast<std::uint8_t>(UINT8_C(1) << lane);
      }
    }
    *activations = packed;
    *m_lane_mask = mask;
    *tile_clear = token.k == 0 ? 1 : 0;
    *reduce_last = token.reduce_last ? 1 : 0;
    return 0;
  } catch (...) {
    return -2;
  }
}

extern "C" int alexnet_golden_window_m16_reset(
    int input_h, int input_w, int channel_count, int kernel, int stride,
    int padding) {
  return alexnet_golden_window_m4_reset(
      input_h, input_w, channel_count, kernel, stride, padding);
}

extern "C" int alexnet_golden_window_m16_set_pixel(
    int y, int x, uint64_t values) {
  return alexnet_golden_window_m4_set_pixel(y, x, values);
}

extern "C" int alexnet_golden_window_m16_token(
    int output_y, int output_x_base, int m_count, int k_index,
    uint64_t* activations_lo, uint64_t* activations_hi,
    uint16_t* m_lane_mask, uint8_t* tile_clear, uint8_t* reduce_last) {
  if (!g_window_m4 || activations_lo == nullptr ||
      activations_hi == nullptr || m_lane_mask == nullptr ||
      tile_clear == nullptr || reduce_last == nullptr || output_y < 0 ||
      output_x_base < 0 || m_count <= 0 || m_count > 16 || k_index < 0) {
    return -1;
  }
  try {
    if (g_window_m4->cached_output_y != output_y ||
        g_window_m4->cached_output_x != output_x_base ||
        g_window_m4->cached_m_count != m_count) {
      g_window_m4->cached_tokens = alexnet::golden::make_window_tokens(
          g_window_m4->input, 0, 0, g_window_m4->channel_count,
          g_window_m4->geometry,
          output_y * g_window_m4->output_w + output_x_base, m_count);
      g_window_m4->cached_output_y = output_y;
      g_window_m4->cached_output_x = output_x_base;
      g_window_m4->cached_m_count = m_count;
    }
    if (k_index >= static_cast<int>(g_window_m4->cached_tokens.size())) {
      return -3;
    }
    const auto& token =
        g_window_m4->cached_tokens[static_cast<std::size_t>(k_index)];
    std::uint64_t packed_lo = 0;
    std::uint64_t packed_hi = 0;
    std::uint16_t mask = 0;
    for (int lane = 0; lane < m_count; ++lane) {
      const auto value = static_cast<std::uint64_t>(
          static_cast<std::uint8_t>(
              token.activations[static_cast<std::size_t>(lane)]));
      if (lane < 8) {
        packed_lo |= value << (lane * 8);
      } else {
        packed_hi |= value << ((lane - 8) * 8);
      }
      if (token.lane_valid[static_cast<std::size_t>(lane)] != 0) {
        mask |= static_cast<std::uint16_t>(UINT16_C(1) << lane);
      }
    }
    *activations_lo = packed_lo;
    *activations_hi = packed_hi;
    *m_lane_mask = mask;
    *tile_clear = token.k == 0 ? 1 : 0;
    *reduce_last = token.reduce_last ? 1 : 0;
    return 0;
  } catch (...) {
    return -2;
  }
}

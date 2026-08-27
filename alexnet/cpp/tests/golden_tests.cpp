#include <cstdint>
#include <cstdlib>
#include <exception>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#include "alexnet_golden/alexnet_ref.hpp"
#include "alexnet_golden/descriptor_ref.hpp"
#include "alexnet_golden/dpi_wrappers.h"
#include "alexnet_golden/layout_ref.hpp"
#include "alexnet_golden/packed_mac_ref.hpp"
#include "alexnet_golden/quant_ref.hpp"
#include "alexnet_golden/sa_tile_ref.hpp"
#include "alexnet_golden/skew_ref.hpp"
#include "alexnet_golden/window_ref.hpp"

namespace ag = alexnet::golden;

namespace {

int g_checks = 0;

void expect(bool condition, const std::string& message) {
  ++g_checks;
  if (!condition) {
    throw std::runtime_error(message);
  }
}

template <typename A, typename B>
void expect_equal(const A& actual, const B& expected,
                  const std::string& message) {
  ++g_checks;
  if (!(actual == expected)) {
    throw std::runtime_error(message + " (actual=" + std::to_string(actual) +
                             ", expected=" + std::to_string(expected) + ")");
  }
}

ag::ConvGeometry geometry(int kernel, int stride = 1, int padding = 0) {
  return ag::ConvGeometry{kernel, kernel, stride, stride, padding, padding, 1, 1};
}

ag::ConvLayerRef identity_conv(int channels) {
  ag::ConvLayerRef layer;
  layer.weights.output_channels = channels;
  layer.weights.input_channels_per_group = channels;
  layer.weights.kernel_h = 1;
  layer.weights.kernel_w = 1;
  layer.weights.values.assign(static_cast<std::size_t>(channels) * channels, 0);
  for (int c = 0; c < channels; ++c) {
    layer.weights.values[static_cast<std::size_t>(c) * channels + c] = 1;
  }
  layer.config.geometry = geometry(1);
  layer.config.groups = 1;
  layer.quant.assign(static_cast<std::size_t>(channels),
                     ag::RequantParams{0, 1, 0, true});
  return layer;
}

void test_quant() {
  expect_equal(ag::round_shift_half_away_from_zero(3, 1), std::int64_t{2},
               "positive half must round away from zero");
  expect_equal(ag::round_shift_half_away_from_zero(-3, 1), std::int64_t{-2},
               "negative half must round away from zero");
  expect_equal(static_cast<int>(ag::requantize(100, {30, 2, 1, false})), 127,
               "requant positive saturation");
  expect_equal(static_cast<int>(ag::requantize(-20, {0, 1, 0, true})), 0,
               "requant ReLU");

  const auto record = ag::pack_parameter_record({-17, 12345, 9, true});
  expect_equal(record.size(), std::size_t{16}, "parameter record size");
  const auto unpacked = ag::unpack_parameter_record(record);
  expect_equal(unpacked.bias, -17, "parameter bias round trip");
  expect_equal(unpacked.multiplier, 12345, "parameter multiplier round trip");
  expect_equal(static_cast<int>(unpacked.right_shift), 9, "parameter shift round trip");
  expect(unpacked.relu, "parameter relu round trip");

  const std::vector<std::int64_t> biased_corners{
      -(std::int64_t{1} << 26), -(std::int64_t{1} << 20) - 1, -1, 0, 1,
      (std::int64_t{1} << 20) - 1, (std::int64_t{1} << 26) - 1};
  const std::vector<std::int32_t> multiplier_corners{0, 1, 65535, 131071};
  for (const auto biased : biased_corners) {
    for (const auto multiplier : multiplier_corners) {
      expect_equal(ag::multiply_s27_s18(biased, multiplier),
                   biased * multiplier, "native s27xs18 corner mismatch");
    }
  }
  std::uint64_t split_state = 0x8a5cd789635d2dffULL;
  for (int index = 0; index < 4096; ++index) {
    split_state = split_state * 6364136223846793005ULL + 1;
    const std::int64_t biased =
        static_cast<std::int64_t>(split_state & ((std::uint64_t{1} << 27) - 1)) -
        (std::int64_t{1} << 26);
    split_state = split_state * 6364136223846793005ULL + 1;
    const std::int32_t multiplier = static_cast<std::int32_t>(split_state & 0x1ffff);
    expect_equal(ag::multiply_s27_s18(biased, multiplier),
                 biased * multiplier, "native s27xs18 random mismatch");
  }
  bool rejected_wide_post_bias = false;
  try {
    static_cast<void>(ag::multiply_s27_s18(std::int64_t{1} << 26, 1));
  } catch (const std::out_of_range&) {
    rejected_wide_post_bias = true;
  }
  expect(rejected_wide_post_bias, "s27 multiplier input range was not enforced");
  bool rejected_wide_multiplier = false;
  try {
    static_cast<void>(ag::multiply_s27_s18(1, std::int32_t{1} << 17));
  } catch (const std::out_of_range&) {
    rejected_wide_multiplier = true;
  }
  expect(rejected_wide_multiplier, "s18 multiplier range was not enforced");
}

void test_packed_mac() {
  const std::vector<int> corners{-128, -127, -1, 0, 1, 126, 127};
  for (const int lo : corners) {
    for (const int hi : corners) {
      for (const int weight : corners) {
        const auto products = ag::packed_products(
            static_cast<std::int8_t>(lo), static_cast<std::int8_t>(hi),
            static_cast<std::int8_t>(weight));
        expect_equal(products.lo, lo * weight, "packed lo product mismatch");
        expect_equal(products.hi, hi * weight, "packed hi product mismatch");
      }
    }
  }

  std::uint32_t state = 0x12345678U;
  for (int iteration = 0; iteration < 10000; ++iteration) {
    state = state * 1664525U + 1013904223U;
    const auto lo = static_cast<std::int8_t>(state >> 24);
    state = state * 1664525U + 1013904223U;
    const auto hi = static_cast<std::int8_t>(state >> 24);
    state = state * 1664525U + 1013904223U;
    const auto weight = static_cast<std::int8_t>(state >> 24);
    const auto products = ag::packed_products(lo, hi, weight);
    expect_equal(products.lo, static_cast<int>(lo) * static_cast<int>(weight),
                 "random packed lo mismatch");
    expect_equal(products.hi, static_cast<int>(hi) * static_cast<int>(weight),
                 "random packed hi mismatch");
  }

  ag::PackedAccumulatorRef accumulator;
  expect(!accumulator.step(2, 3, 4, true, 3, true, false).has_value(),
         "non-last packed step emitted a result");
  const auto result = accumulator.step(-1, 5, 2, true, 1, false, true);
  expect(result.has_value(), "last packed step did not emit a result");
  expect_equal(result->lo, 6, "packed accumulator lo");
  expect_equal(result->hi, 22, "packed accumulator hi");
  expect_equal(static_cast<int>(result->lane_mask), 1, "packed accumulator mask");
}

void test_sa_tile() {
  ag::MatrixI8 activations(5, 4,
                           {1, 2, 3, 4,
                            -1, 0, 2, 1,
                            3, -2, 1, 0,
                            5, 4, -3, 2,
                            -4, 1, 2, -2});
  ag::MatrixI8 weights(3, 4,
                       {1, 0, -1, 2,
                        2, 3, 1, -1,
                        -2, 1, 0, 4});
  const auto packed = ag::packed_os_matmul_tile(activations, weights);
  const auto dense = ag::linear_accumulate(activations, weights);
  expect_equal(packed.rows(), 5, "SA tile M count");
  expect_equal(packed.cols(), 3, "SA tile N count");
  for (int m = 0; m < packed.rows(); ++m) {
    for (int n = 0; n < packed.cols(); ++n) {
      expect_equal(packed.at(m, n), dense.at(m, n),
                   "packed SA tile must equal dense matmul");
    }
  }
}

void test_window_and_layout() {
  ag::TensorI8 input(1, 1, 3, 4);
  for (int y = 0; y < input.h(); ++y) {
    for (int x = 0; x < input.w(); ++x) {
      input.at(0, 0, y, x) = static_cast<std::int8_t>(1 + y * input.w() + x);
    }
  }
  const auto tokens = ag::make_window_tokens(input, 0, 0, 1, geometry(3, 2, 1),
                                              0, 8);
  expect_equal(tokens.size(), std::size_t{9}, "window K token count");
  expect_equal(tokens.front().k, 0, "window first K tag");
  expect_equal(static_cast<int>(tokens.front().activations[0]), 0,
               "window top-left padding value");
  expect_equal(static_cast<int>(tokens[4].activations[0]), 1,
               "window center value");
  expect(tokens.back().reduce_last, "window reduce_last missing");
  expect_equal(static_cast<int>(tokens.front().lane_valid[4]), 0,
               "window spatial tail lane must be invalid");

  ag::ConvWeightsI8 weights;
  weights.output_channels = 2;
  weights.input_channels_per_group = 2;
  weights.kernel_h = 2;
  weights.kernel_w = 2;
  weights.values.resize(16);
  for (std::size_t index = 0; index < weights.values.size(); ++index) {
    weights.values[index] = static_cast<std::int8_t>(index + 1);
  }
  const auto packed = ag::pack_weight_tile_k_major(weights, 0, 4);
  expect_equal(packed.size(), std::size_t{32}, "K-major packed weight size");
  // k=(ky=0,kx=0,ic=1), followed by output lanes 0,1,tail,tail.
  expect_equal(static_cast<int>(packed[4]), 5, "K-major oc0 mapping");
  expect_equal(static_cast<int>(packed[5]), 13, "K-major oc1 mapping");
  expect_equal(static_cast<int>(packed[6]), 0, "K-major tail zero");

  ag::ConvWeightsI8 grouped_weights{6, 2, 1, 1,
                                    {1, 2, 3, 4, 5, 6,
                                     7, 8, 9, 10, 11, 12}};
  const auto group_tail =
      ag::pack_weight_tile_k_major(grouped_weights, 2, 4, 1);
  expect_equal(static_cast<int>(group_tail[0]), 5,
               "group weight tile first valid lane");
  expect_equal(static_cast<int>(group_tail[1]), 0,
               "group weight tile must not read the next group");
  expect_equal(static_cast<int>(group_tail[4]), 6,
               "group weight tile next K value");

  const auto bursts = ag::make_dma_bursts(0x1FF0, 5000);
  expect_equal(bursts.size(), std::size_t{3}, "DMA burst split count");
  expect_equal(bursts[0].address, std::uint64_t{0x1FF0},
               "DMA first burst address");
  expect_equal(bursts[0].valid_bytes, std::size_t{16},
               "DMA 4 KiB boundary tail");
  expect_equal(bursts[1].valid_bytes, std::size_t{4096},
               "DMA full burst size");
  expect_equal(bursts[2].valid_bytes, std::size_t{888},
               "DMA final partial bytes");
  expect_equal(bursts[2].beat_count, std::size_t{56},
               "DMA final partial beat count");

  ag::PingPongTileBufferRef banks;
  banks.begin_dma(0);
  banks.complete_dma(0, true);
  banks.begin_compute(0);
  banks.begin_dma(1);
  expect_equal(static_cast<int>(banks.state(0)),
               static_cast<int>(ag::TileBankState::kCompute),
               "ping bank compute ownership");
  expect_equal(static_cast<int>(banks.state(1)),
               static_cast<int>(ag::TileBankState::kDmaFill),
               "pong bank DMA overlap ownership");
  banks.complete_dma(1, true);
  bool rejected_early_swap = false;
  try {
    banks.begin_compute(1);
  } catch (const std::logic_error&) {
    rejected_early_swap = true;
  }
  expect(rejected_early_swap, "ping-pong must reject mid-compute bank swap");
  banks.complete_compute(0);
  banks.begin_compute(1);
  banks.complete_compute(1);
  expect_equal(static_cast<int>(banks.state(1)),
               static_cast<int>(ag::TileBankState::kEmpty),
               "pong bank release after compute");

  const auto order = ag::make_postprocess_scan_order(32, 64);
  expect_equal(order.size(), std::size_t{32}, "postprocess cycle count");
  expect_equal(order.front().size(), std::size_t{64}, "postprocess lanes per cycle");
  expect_equal(order.front()[0].m, 0, "postprocess first m");
  expect_equal(order.front()[63].n, 63, "postprocess last N lane");
  expect_equal(order[1][0].m, 1, "postprocess next M position");
  expect_equal(order.back()[0].m, 31, "postprocess final M position");
  std::vector<bool> postprocess_seen(32 * 64, false);
  bool postprocess_coverage_ok = true;
  for (const auto& cycle : order) {
    for (const auto& coordinate : cycle) {
      const auto flat = static_cast<std::size_t>(coordinate.m * 64 + coordinate.n);
      if (flat >= postprocess_seen.size() || postprocess_seen[flat]) {
        postprocess_coverage_ok = false;
      } else {
        postprocess_seen[flat] = true;
      }
    }
  }
  for (const bool seen : postprocess_seen) {
    postprocess_coverage_ok = postprocess_coverage_ok && seen;
  }
  expect(postprocess_coverage_ok, "postprocess scan coverage or uniqueness failed");

  const auto n_tail_order = ag::make_postprocess_scan_order(32, 40, 64, 960);
  expect_equal(n_tail_order.size(), std::size_t{32}, "N40 tail cycle count");
  expect_equal(n_tail_order.front().size(), std::size_t{40}, "N40 active lanes");
  expect_equal(n_tail_order.front().front().n, 960, "N40 global base channel");
  expect_equal(n_tail_order.back().back().n, 999, "N40 final active lane");
  bool rejected_oversized_n_tile = false;
  try {
    static_cast<void>(ag::make_postprocess_scan_order(32, 65));
  } catch (const std::invalid_argument&) {
    rejected_oversized_n_tile = true;
  }
  expect(rejected_oversized_n_tile, "postprocess accepted an N tile wider than 64");

  ag::PostprocessScannerRef scanner(2, 64);
  const auto stalled_first = scanner.tick(false);
  const auto stalled_again = scanner.tick(false);
  expect(stalled_first.has_value() && stalled_again.has_value(),
         "postprocess scanner lost valid during stall");
  expect_equal(stalled_again->front().m, stalled_first->front().m,
               "postprocess scanner changed M during stall");
  expect_equal(stalled_again->back().n, stalled_first->back().n,
               "postprocess scanner changed N during stall");
  static_cast<void>(scanner.tick(true));
  const auto second_m = scanner.tick(true);
  expect(second_m.has_value(), "postprocess scanner missed second M position");
  expect_equal(second_m->front().m, 1, "postprocess scanner advance after ready");
  expect(scanner.done(), "postprocess scanner did not finish after two transfers");
  scanner.reset();
  expect(!scanner.done(), "postprocess scanner reset failed");

  ag::PostprocessScannerRef stalled_slice(2, 8, 8, 0);
  ag::PostprocessScannerRef running_slice(2, 8, 8, 8);
  static_cast<void>(stalled_slice.tick(false));
  static_cast<void>(running_slice.tick(true));
  const auto stalled_slice_next = stalled_slice.tick(false);
  const auto running_slice_next = running_slice.tick(false);
  expect_equal(stalled_slice_next->front().m, 0,
               "stalled N8 slice advanced its M coordinate");
  expect_equal(running_slice_next->front().m, 1,
               "independent N8 slice did not advance");
  expect_equal(running_slice_next->front().n, 8,
               "independent N8 slice lost its global N base");

  expect_equal(ag::pack_i8_pair_le(-1, -128), std::uint16_t{0x80FF},
               "packed pair little endian");
}

void test_conv_and_pool() {
  ag::TensorI8 input(1, 1, 3, 3,
                     {1, 2, 3,
                      4, 5, 6,
                      7, 8, 9});
  ag::ConvWeightsI8 weights{1, 1, 2, 2, {1, 0, 0, -1}};
  ag::Conv2DConfig config{geometry(2), 1};
  const auto accum = ag::conv2d_accumulate(input, weights, config);
  expect_equal(accum.h(), 2, "dense conv output height");
  expect_equal(accum.w(), 2, "dense conv output width");
  expect_equal(accum.at(0, 0, 0, 0), -4, "dense conv point 0");
  expect_equal(accum.at(0, 0, 1, 1), -4, "dense conv point 3");

  ag::TensorI8 grouped_input(1, 4, 1, 1, {1, 2, 10, 20});
  ag::ConvWeightsI8 grouped_weights{4, 2, 1, 1,
                                    {1, 1, 2, 0, 1, 1, 0, 2}};
  const auto grouped = ag::conv2d_accumulate(
      grouped_input, grouped_weights, {geometry(1), 2});
  expect_equal(grouped.at(0, 0, 0, 0), 3, "group conv output 0");
  expect_equal(grouped.at(0, 1, 0, 0), 2, "group conv output 1");
  expect_equal(grouped.at(0, 2, 0, 0), 30, "group conv output 2");
  expect_equal(grouped.at(0, 3, 0, 0), 40, "group conv output 3");

  ag::TensorI8 pool_input(1, 1, 5, 5);
  for (int index = 0; index < 25; ++index) {
    pool_input.data()[static_cast<std::size_t>(index)] =
        static_cast<std::int8_t>(index - 12);
  }
  const auto pooled = ag::maxpool2d(pool_input, {3, 3, 2, 2, 0, 0});
  expect_equal(pooled.h(), 2, "pool output height");
  expect_equal(pooled.w(), 2, "pool output width");
  expect_equal(static_cast<int>(pooled.at(0, 0, 0, 0)), 0, "pool first maximum");
  expect_equal(static_cast<int>(pooled.at(0, 0, 1, 1)), 12, "pool last maximum");
}

void test_linear() {
  ag::MatrixI8 input(2, 3, {1, 2, 3, -1, 0, 2});
  ag::MatrixI8 weights(2, 3, {1, 0, -1, 2, 3, 4});
  const auto accum = ag::linear_accumulate(input, weights);
  expect_equal(accum.at(0, 0), -2, "linear b0n0");
  expect_equal(accum.at(0, 1), 20, "linear b0n1");
  expect_equal(accum.at(1, 0), -3, "linear b1n0");
  expect_equal(accum.at(1, 1), 6, "linear b1n1");
  const auto output = ag::linear_requantize(accum, {{0, 1, 0, true}});
  expect_equal(static_cast<int>(output.at(0, 0)), 0, "linear ReLU");
  expect_equal(static_cast<int>(output.at(0, 1)), 20, "linear requant");
}

void test_descriptor() {
  ag::RuntimeDescriptor conv1;
  conv1.op = ag::OperatorKind::kConv2D;
  conv1.batch = 1;
  conv1.input_channels = 3;
  conv1.input_h = 224;
  conv1.input_w = 224;
  conv1.output_channels = 64;
  conv1.geometry = geometry(11, 4, 2);
  const auto derived = ag::derive_descriptor(conv1);
  expect_equal(derived.output_h, 55, "Conv1 descriptor output H");
  expect_equal(derived.output_w, 55, "Conv1 descriptor output W");
  expect_equal(derived.k_depth, 363, "Conv1 descriptor K");
  const auto schedule = ag::make_weight_major_schedule(conv1);
  expect_equal(schedule.size(), std::size_t{95}, "Conv1 spatial tile count");
  expect(schedule.front().first_for_weight_tile, "Conv1 first tile marker");
  expect(schedule.back().last_for_weight_tile, "Conv1 last tile marker");
  expect_equal(ag::weight_tile_bytes(conv1, schedule.front()),
               std::size_t{23232}, "Conv1 weight tile bytes");

  ag::RuntimeDescriptor original_conv2;
  original_conv2.op = ag::OperatorKind::kConv2D;
  original_conv2.input_channels = 96;
  original_conv2.input_h = 27;
  original_conv2.input_w = 27;
  original_conv2.output_channels = 256;
  original_conv2.groups = 2;
  original_conv2.geometry = geometry(5, 1, 2);
  const auto grouped = ag::derive_descriptor(original_conv2);
  expect_equal(grouped.k_depth, 1200, "original grouped Conv2 K");
  expect_equal(grouped.n_tiles_per_group, 2, "original grouped Conv2 N tiles");
  expect_equal(ag::make_weight_major_schedule(original_conv2).size(),
               std::size_t{92}, "original grouped Conv2 work item count");
  const auto grouped_schedule =
      ag::make_weight_major_schedule(original_conv2);
  const auto addresses = ag::resolve_tile_ddr_addresses(
      original_conv2, grouped_schedule[46],
      {0x01000000, 0x02000000, 0x03000000, 0x04000000});
  expect_equal(addresses.weight, std::uint64_t{0x02025800},
               "grouped Conv2 weight tile DDR address");
  expect_equal(addresses.parameter, std::uint64_t{0x03000800},
               "grouped Conv2 parameter DDR address");
  expect_equal(addresses.first_output, std::uint64_t{0x04016C80},
               "grouped Conv2 first output DDR address");

  ag::RuntimeDescriptor fc6;
  fc6.op = ag::OperatorKind::kLinear;
  fc6.batch = 64;
  fc6.input_channels = 9216;
  fc6.output_channels = 4096;
  fc6.input_h = 1;
  fc6.input_w = 1;
  const auto fc_schedule = ag::make_weight_major_schedule(fc6);
  expect_equal(fc_schedule.size(), std::size_t{128}, "FC6 batch-wave schedule");
}

void test_skew() {
  ag::LocalSkewRef skew;
  for (int cycle = 0; cycle < 10; ++cycle) {
    ag::SkewInputs inputs;
    inputs.activations.resize(4);
    inputs.weights.resize(8);
    for (int group = 0; group < 4; ++group) {
      inputs.activations[static_cast<std::size_t>(group)] =
          ag::ActivationPairToken{static_cast<std::int8_t>(cycle + 1), 0, true,
                                  3, false, cycle, 7};
    }
    for (int column = 0; column < 8; ++column) {
      inputs.weights[static_cast<std::size_t>(column)] =
          ag::WeightToken{static_cast<std::int8_t>(cycle + 1), true, false,
                          cycle, 7};
    }
    const auto outputs = skew.tick(true, inputs);
    expect_equal(static_cast<int>(outputs.activations[0].lo), cycle + 1,
                 "zero-delay activation path");
    if (cycle >= 3) {
      expect_equal(outputs.activations[3].k_tag, cycle - 3,
                   "activation group-3 delay");
    }
    if (cycle >= 7) {
      expect_equal(outputs.weights[7].k_tag, cycle - 7,
                   "weight column-7 delay");
    }
  }
  expect_equal(ag::pe_alignment_cycle(100, 9, 3, 7), 119,
               "PE alignment formula");

  ag::SkewInputs held;
  held.activations.resize(4);
  held.weights.resize(8);
  const auto before = skew.tick(false, held);
  const auto after = skew.tick(false, held);
  expect_equal(after.activations[3].k_tag, before.activations[3].k_tag,
               "skew activation hold");
  expect_equal(after.weights[7].k_tag, before.weights[7].k_tag,
               "skew weight hold");
}

void test_mini_full_network() {
  ag::TensorI8 input(1, 1, 15, 15);
  for (int index = 0; index < 225; ++index) {
    input.data()[static_cast<std::size_t>(index)] =
        static_cast<std::int8_t>(index % 100);
  }

  ag::AlexNetInt8Parameters parameters;
  parameters.conv1 = identity_conv(1);
  parameters.conv2 = identity_conv(1);
  parameters.conv3 = identity_conv(1);
  parameters.conv4 = identity_conv(1);
  parameters.conv5 = identity_conv(1);
  parameters.fc6.weights = ag::MatrixI8(2, 1, {1, 2});
  parameters.fc6.quant = {{0, 1, 0, true}, {0, 1, 0, true}};
  parameters.fc7.weights = ag::MatrixI8(2, 2, {1, 0, 0, 1});
  parameters.fc7.quant = {{0, 1, 0, true}};
  parameters.fc8.weights = ag::MatrixI8(1, 2, {1, -1});
  parameters.fc8.quant = {{0, 1, 0, false}};

  const auto outputs = ag::run_alexnet_int8(input, parameters);
  expect_equal(outputs.pool5.h(), 1, "mini AlexNet pool5 H");
  expect_equal(outputs.pool5.w(), 1, "mini AlexNet pool5 W");
  expect_equal(outputs.logits.rows(), 1, "mini AlexNet logits batch");
  expect_equal(outputs.logits.cols(), 1, "mini AlexNet logits count");
  expect_equal(static_cast<int>(outputs.logits.at(0, 0)), -28,
               "mini AlexNet final value");
}

void test_dpi_wrappers() {
  std::int32_t lo = 0;
  std::int32_t hi = 0;
  expect_equal(alexnet_golden_packed_products(-7, 11, 9, &lo, &hi), 0,
               "DPI packed status");
  expect_equal(lo, -63, "DPI packed lo");
  expect_equal(hi, 99, "DPI packed hi");

  std::int8_t output = 0;
  expect_equal(alexnet_golden_requantize(-3, 0, 1, 1, 0, &output), 0,
               "DPI requant status");
  expect_equal(static_cast<int>(output), -2, "DPI requant value");
}

}  // namespace

int main() {
  try {
    test_quant();
    test_packed_mac();
    test_sa_tile();
    test_window_and_layout();
    test_conv_and_pool();
    test_linear();
    test_descriptor();
    test_skew();
    test_mini_full_network();
    test_dpi_wrappers();
    std::cout << "alexnet_golden_tests: PASS (" << g_checks << " checks)\n";
    return EXIT_SUCCESS;
  } catch (const std::exception& error) {
    std::cerr << "alexnet_golden_tests: FAIL after " << g_checks
              << " checks: " << error.what() << '\n';
    return EXIT_FAILURE;
  }
}

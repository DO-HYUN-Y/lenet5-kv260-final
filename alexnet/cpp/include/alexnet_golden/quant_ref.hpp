#pragma once

#include <cstdint>
#include <vector>

namespace alexnet::golden {

// Numeric contract used by the first AlexNet INT8 RTL:
//   biased = accumulator + bias
//   scaled = round_half_away_from_zero(biased * multiplier / 2^right_shift)
//   optional ReLU, then signed INT8 saturation.
// multiplier is required to be non-negative. Numeric zero is bit-pattern zero.
struct RequantParams {
  std::int32_t bias = 0;
  std::int32_t multiplier = 1;
  std::uint8_t right_shift = 0;
  bool relu = false;
};

std::int64_t round_shift_half_away_from_zero(std::int64_t value,
                                            std::uint8_t right_shift);
// Exact DSP48E2-native signed 27-bit x non-negative signed 18-bit product.
// The frozen AlexNet weights have a checked all-input post-bias bound of 27 bits.
std::int64_t multiply_s27_s18(std::int64_t biased, std::int32_t multiplier);
std::int8_t saturate_i8(std::int64_t value);
std::int8_t requantize(std::int32_t accumulator, const RequantParams& params);

const RequantParams& channel_params(const std::vector<RequantParams>& params,
                                    int output_channel);

}  // namespace alexnet::golden

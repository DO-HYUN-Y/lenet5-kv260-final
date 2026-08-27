#include "alexnet_golden/quant_ref.hpp"

#include <limits>
#include <stdexcept>

namespace alexnet::golden {

std::int64_t round_shift_half_away_from_zero(std::int64_t value,
                                            std::uint8_t right_shift) {
  if (right_shift == 0) {
    return value;
  }
  if (right_shift >= 63) {
    throw std::invalid_argument("right_shift must be in the range 0..62");
  }

  const std::uint64_t magnitude =
      value < 0 ? static_cast<std::uint64_t>(-value)
                : static_cast<std::uint64_t>(value);
  const std::uint64_t rounded =
      (magnitude + (std::uint64_t{1} << (right_shift - 1))) >> right_shift;
  return value < 0 ? -static_cast<std::int64_t>(rounded)
                   : static_cast<std::int64_t>(rounded);
}

std::int8_t saturate_i8(std::int64_t value) {
  if (value > std::numeric_limits<std::int8_t>::max()) {
    return std::numeric_limits<std::int8_t>::max();
  }
  if (value < std::numeric_limits<std::int8_t>::min()) {
    return std::numeric_limits<std::int8_t>::min();
  }
  return static_cast<std::int8_t>(value);
}

std::int8_t requantize(std::int32_t accumulator, const RequantParams& params) {
  if (params.multiplier < 0) {
    throw std::invalid_argument("requant multiplier must be non-negative");
  }

  const std::int64_t biased = static_cast<std::int64_t>(accumulator) + params.bias;
  const std::int64_t product = biased * static_cast<std::int64_t>(params.multiplier);
  std::int64_t scaled = round_shift_half_away_from_zero(product, params.right_shift);
  if (params.relu && scaled < 0) {
    scaled = 0;
  }
  return saturate_i8(scaled);
}

const RequantParams& channel_params(const std::vector<RequantParams>& params,
                                    int output_channel) {
  if (params.empty()) {
    throw std::invalid_argument("requant parameter vector must not be empty");
  }
  if (params.size() == 1) {
    return params.front();
  }
  if (output_channel < 0 ||
      static_cast<std::size_t>(output_channel) >= params.size()) {
    throw std::out_of_range("requant output channel is out of range");
  }
  return params[static_cast<std::size_t>(output_channel)];
}

}  // namespace alexnet::golden

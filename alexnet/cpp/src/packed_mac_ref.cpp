#include "alexnet_golden/packed_mac_ref.hpp"

#include <limits>
#include <stdexcept>

namespace alexnet::golden {
namespace {

constexpr int kPackingShift = 18;
constexpr std::uint64_t kProductMask36 = (std::uint64_t{1} << 36) - 1;

std::int32_t sign_extend_18(std::uint32_t value) {
  value &= 0x3FFFFU;
  if ((value & 0x20000U) != 0U) {
    value |= 0xFFFC0000U;
  }
  return static_cast<std::int32_t>(value);
}

std::int32_t checked_add(std::int32_t accumulator, std::int32_t product) {
  const std::int64_t sum = static_cast<std::int64_t>(accumulator) + product;
  if (sum < std::numeric_limits<std::int32_t>::min() ||
      sum > std::numeric_limits<std::int32_t>::max()) {
    throw std::overflow_error("INT32 packed accumulator overflow");
  }
  return static_cast<std::int32_t>(sum);
}

}  // namespace

PackedProducts packed_products(std::int8_t act_lo, std::int8_t act_hi,
                               std::int8_t weight) {
  // Multiplication is used instead of left-shifting a negative signed value,
  // which would be undefined behavior in C++.
  const std::int64_t ad =
      static_cast<std::int64_t>(act_hi) * (std::int64_t{1} << kPackingShift) +
      static_cast<std::int64_t>(act_lo);
  const std::int64_t product = ad * static_cast<std::int64_t>(weight);
  const std::uint64_t bits = static_cast<std::uint64_t>(product) & kProductMask36;

  PackedProducts result;
  result.lo = sign_extend_18(static_cast<std::uint32_t>(bits));
  result.hi = sign_extend_18(static_cast<std::uint32_t>(bits >> kPackingShift)) +
              static_cast<std::int32_t>((bits >> 17) & 1U);
  return result;
}

void PackedAccumulatorRef::reset() {
  acc_lo_ = 0;
  acc_hi_ = 0;
}

std::optional<PackedAccumulatorResult> PackedAccumulatorRef::step(
    std::int8_t act_lo, std::int8_t act_hi, std::int8_t weight,
    bool pair_valid, std::uint8_t lane_mask, bool acc_clear,
    bool reduce_last) {
  if ((lane_mask & ~0x3U) != 0U) {
    throw std::invalid_argument("packed lane mask must be two bits");
  }
  if (acc_clear) {
    reset();
  }
  if (!pair_valid) {
    return std::nullopt;
  }

  const PackedProducts products = packed_products(act_lo, act_hi, weight);
  acc_lo_ = checked_add(acc_lo_, products.lo);
  acc_hi_ = checked_add(acc_hi_, products.hi);

  if (!reduce_last) {
    return std::nullopt;
  }

  PackedAccumulatorResult result{acc_lo_, acc_hi_, lane_mask};
  reset();
  return result;
}

}  // namespace alexnet::golden

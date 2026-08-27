#pragma once

#include <cstdint>
#include <optional>

namespace alexnet::golden {

struct PackedProducts {
  std::int32_t lo = 0;
  std::int32_t hi = 0;
};

struct PackedAccumulatorResult {
  std::int32_t lo = 0;
  std::int32_t hi = 0;
  std::uint8_t lane_mask = 0;
};

PackedProducts packed_products(std::int8_t act_lo, std::int8_t act_hi,
                               std::int8_t weight);

class PackedAccumulatorRef {
 public:
  void reset();

  std::optional<PackedAccumulatorResult> step(std::int8_t act_lo,
                                               std::int8_t act_hi,
                                               std::int8_t weight,
                                               bool pair_valid,
                                               std::uint8_t lane_mask,
                                               bool acc_clear,
                                               bool reduce_last);

 private:
  std::int32_t acc_lo_ = 0;
  std::int32_t acc_hi_ = 0;
};

}  // namespace alexnet::golden

#include "alexnet_golden/sa_tile_ref.hpp"

#include <cstdint>
#include <stdexcept>

#include "alexnet_golden/packed_mac_ref.hpp"

namespace alexnet::golden {

MatrixI32 packed_os_matmul_tile(const MatrixI8& activations,
                                const MatrixI8& weights) {
  if (activations.cols() != weights.cols()) {
    throw std::invalid_argument("SA activation K does not match weight K");
  }
  MatrixI32 output(activations.rows(), weights.rows());

  for (int m_pair = 0; m_pair < activations.rows(); m_pair += 2) {
    const bool hi_valid = m_pair + 1 < activations.rows();
    const std::uint8_t lane_mask = hi_valid ? 0x3U : 0x1U;
    for (int n = 0; n < weights.rows(); ++n) {
      PackedAccumulatorRef accumulator;
      for (int k = 0; k < activations.cols(); ++k) {
        const std::int8_t lo = activations.at(m_pair, k);
        const std::int8_t hi = hi_valid ? activations.at(m_pair + 1, k)
                                        : std::int8_t{0};
        const auto result = accumulator.step(
            lo, hi, weights.at(n, k), true, lane_mask, k == 0,
            k == activations.cols() - 1);
        if (k == activations.cols() - 1) {
          if (!result.has_value()) {
            throw std::logic_error("SA final K did not produce a result");
          }
          output.at(m_pair, n) = result->lo;
          if (hi_valid) {
            output.at(m_pair + 1, n) = result->hi;
          }
        } else if (result.has_value()) {
          throw std::logic_error("SA non-final K produced a result");
        }
      }
    }
  }
  return output;
}

}  // namespace alexnet::golden

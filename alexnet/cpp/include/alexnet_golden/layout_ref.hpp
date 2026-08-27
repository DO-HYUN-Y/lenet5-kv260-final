#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <vector>

#include "alexnet_golden/conv2d_ref.hpp"
#include "alexnet_golden/quant_ref.hpp"
#include "alexnet_golden/tensor.hpp"

namespace alexnet::golden {

struct OutputCoordinate {
  int m = 0;
  int n = 0;
};

std::uint16_t pack_i8_pair_le(std::int8_t lo, std::int8_t hi);
std::int8_t unpack_i8_pair_lo(std::uint16_t packed);
std::int8_t unpack_i8_pair_hi(std::uint16_t packed);

std::vector<std::uint8_t> pack_activation_nchw(const TensorI8& tensor);
TensorI8 unpack_activation_nchw(const std::vector<std::uint8_t>& bytes,
                                int n, int c, int h, int w);

// Packs one output-channel tile in [k][output_channel_lane] order. Logical
// OIHW is converted to the SA K order [kernel_y][kernel_x][input_channel].
// Output-channel tail lanes are zero-filled.
std::vector<std::int8_t> pack_weight_tile_k_major(
    const ConvWeightsI8& weights, int output_channel_base, int n_tile,
    int output_channel_count = -1);

// Row-major linear weights [N][K] become [k][n_lane].
std::vector<std::int8_t> pack_linear_weight_tile_k_major(
    const MatrixI8& weights, int output_feature_base, int n_tile);

// Fixed 16-byte little-endian parameter record used by the reference layout:
// bias[31:0], multiplier[31:0], shift[7:0], flags[7:0], six zero bytes.
std::vector<std::uint8_t> pack_parameter_record(const RequantParams& params);
RequantParams unpack_parameter_record(const std::vector<std::uint8_t>& record);

// N-stationary postprocess scan. Each physical lane owns one output channel and
// scans the M dimension; M32/N64 therefore emits 64 results for 32 cycles.
// n_count is one hardware tile and must not exceed n_lanes; smaller N tails mask
// the unused lanes without adding drain cycles. n_base preserves the global
// output-channel tag for independent N8 slices and the final FC8 tile.
std::vector<std::vector<OutputCoordinate>> make_postprocess_scan_order(
    int m_count, int n_count, int n_lanes = 64, int n_base = 0);

// Cycle model for ready/valid verification. tick() exposes the coordinates
// visible before the edge and advances only on ready, so a stall holds all tags.
class PostprocessScannerRef {
 public:
  PostprocessScannerRef(int m_count, int n_count, int n_lanes = 64,
                        int n_base = 0);
  void reset();
  std::optional<std::vector<OutputCoordinate>> tick(bool ready);
  bool done() const { return cycle_index_ == schedule_.size(); }

 private:
  std::vector<std::vector<OutputCoordinate>> schedule_;
  std::size_t cycle_index_ = 0;
};

struct DmaBurst {
  std::uint64_t address = 0;
  std::size_t valid_bytes = 0;
  std::size_t beat_count = 0;
};

// Splits a logical transfer into aligned AXI bursts which never cross a 4 KiB
// boundary. The last beat may be partial and is described by valid_bytes.
std::vector<DmaBurst> make_dma_bursts(std::uint64_t address,
                                      std::size_t byte_count,
                                      std::size_t beat_bytes = 16,
                                      std::size_t max_burst_bytes = 4096);

enum class TileBankState { kEmpty, kDmaFill, kReady, kCompute };

// Transaction-level ownership oracle for a two-bank weight/activation tile
// buffer. It intentionally models handshakes, not clock latency.
class PingPongTileBufferRef {
 public:
  void reset();
  void begin_dma(int bank);
  void complete_dma(int bank, bool success);
  void begin_compute(int bank);
  void complete_compute(int bank);

  TileBankState state(int bank) const;
  int compute_bank() const { return compute_bank_; }

 private:
  static std::size_t checked_bank(int bank);

  std::array<TileBankState, 2> states_{TileBankState::kEmpty,
                                       TileBankState::kEmpty};
  int compute_bank_ = -1;
};

}  // namespace alexnet::golden

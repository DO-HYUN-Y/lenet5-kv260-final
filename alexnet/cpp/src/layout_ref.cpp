#include "alexnet_golden/layout_ref.hpp"

#include <algorithm>
#include <limits>
#include <stdexcept>

namespace alexnet::golden {
namespace {

void append_i32_le(std::vector<std::uint8_t>* bytes, std::int32_t value) {
  const std::uint32_t bits = static_cast<std::uint32_t>(value);
  for (int i = 0; i < 4; ++i) {
    bytes->push_back(static_cast<std::uint8_t>((bits >> (8 * i)) & 0xFFU));
  }
}

std::int32_t read_i32_le(const std::vector<std::uint8_t>& bytes,
                         std::size_t offset) {
  std::uint32_t value = 0;
  for (int i = 0; i < 4; ++i) {
    value |= static_cast<std::uint32_t>(bytes.at(offset + i)) << (8 * i);
  }
  return static_cast<std::int32_t>(value);
}

}  // namespace

std::uint16_t pack_i8_pair_le(std::int8_t lo, std::int8_t hi) {
  return static_cast<std::uint16_t>(static_cast<std::uint8_t>(lo)) |
         (static_cast<std::uint16_t>(static_cast<std::uint8_t>(hi)) << 8);
}

std::int8_t unpack_i8_pair_lo(std::uint16_t packed) {
  return static_cast<std::int8_t>(packed & 0xFFU);
}

std::int8_t unpack_i8_pair_hi(std::uint16_t packed) {
  return static_cast<std::int8_t>((packed >> 8) & 0xFFU);
}

std::vector<std::uint8_t> pack_activation_nchw(const TensorI8& tensor) {
  std::vector<std::uint8_t> bytes;
  bytes.reserve(tensor.size());
  for (const std::int8_t value : tensor.data()) {
    bytes.push_back(static_cast<std::uint8_t>(value));
  }
  return bytes;
}

TensorI8 unpack_activation_nchw(const std::vector<std::uint8_t>& bytes,
                                int n, int c, int h, int w) {
  std::vector<std::int8_t> values;
  values.reserve(bytes.size());
  for (const std::uint8_t value : bytes) {
    values.push_back(static_cast<std::int8_t>(value));
  }
  return TensorI8(n, c, h, w, std::move(values));
}

std::vector<std::int8_t> pack_weight_tile_k_major(
    const ConvWeightsI8& weights, int output_channel_base, int n_tile,
    int output_channel_count) {
  weights.validate();
  if (output_channel_base < 0 || output_channel_base >= weights.output_channels ||
      n_tile <= 0) {
    throw std::invalid_argument("invalid convolution output-channel tile");
  }
  if (output_channel_count < 0) {
    output_channel_count =
        std::min(n_tile, weights.output_channels - output_channel_base);
  }
  if (output_channel_count <= 0 || output_channel_count > n_tile ||
      output_channel_base + output_channel_count > weights.output_channels) {
    throw std::invalid_argument("invalid convolution output-channel count");
  }

  const int k_depth = weights.input_channels_per_group * weights.kernel_h *
                      weights.kernel_w;
  std::vector<std::int8_t> packed;
  packed.reserve(static_cast<std::size_t>(k_depth) * n_tile);

  for (int ky = 0; ky < weights.kernel_h; ++ky) {
    for (int kx = 0; kx < weights.kernel_w; ++kx) {
      for (int ic = 0; ic < weights.input_channels_per_group; ++ic) {
        for (int lane = 0; lane < n_tile; ++lane) {
          const int oc = output_channel_base + lane;
          packed.push_back(lane < output_channel_count
                               ? weights.at(oc, ic, ky, kx)
                               : std::int8_t{0});
        }
      }
    }
  }
  return packed;
}

std::vector<std::int8_t> pack_linear_weight_tile_k_major(
    const MatrixI8& weights, int output_feature_base, int n_tile) {
  if (output_feature_base < 0 || output_feature_base >= weights.rows() ||
      n_tile <= 0) {
    throw std::invalid_argument("invalid linear output-feature tile");
  }
  std::vector<std::int8_t> packed;
  packed.reserve(static_cast<std::size_t>(weights.cols()) * n_tile);
  for (int k = 0; k < weights.cols(); ++k) {
    for (int lane = 0; lane < n_tile; ++lane) {
      const int output_feature = output_feature_base + lane;
      packed.push_back(output_feature < weights.rows()
                           ? weights.at(output_feature, k)
                           : std::int8_t{0});
    }
  }
  return packed;
}

std::vector<std::uint8_t> pack_parameter_record(const RequantParams& params) {
  if (params.multiplier < 0) {
    throw std::invalid_argument("parameter multiplier must be non-negative");
  }
  std::vector<std::uint8_t> record;
  record.reserve(16);
  append_i32_le(&record, params.bias);
  append_i32_le(&record, params.multiplier);
  record.push_back(params.right_shift);
  record.push_back(params.relu ? 1U : 0U);
  while (record.size() < 16) {
    record.push_back(0);
  }
  return record;
}

RequantParams unpack_parameter_record(const std::vector<std::uint8_t>& record) {
  if (record.size() != 16) {
    throw std::invalid_argument("parameter record must contain exactly 16 bytes");
  }
  RequantParams params;
  params.bias = read_i32_le(record, 0);
  params.multiplier = read_i32_le(record, 4);
  params.right_shift = record[8];
  params.relu = (record[9] & 1U) != 0U;
  return params;
}

std::vector<std::vector<OutputCoordinate>> make_postprocess_scan_order(
    int m_count, int n_count, int n_lanes, int n_base) {
  if (m_count <= 0 || n_count <= 0 || n_lanes <= 0 || n_count > n_lanes ||
      n_base < 0 || n_base > std::numeric_limits<int>::max() - n_count) {
    throw std::invalid_argument("invalid postprocess scan geometry");
  }
  std::vector<std::vector<OutputCoordinate>> cycles;
  cycles.reserve(static_cast<std::size_t>(m_count));

  for (int m = 0; m < m_count; ++m) {
    std::vector<OutputCoordinate> cycle;
    cycle.reserve(static_cast<std::size_t>(n_count));
    for (int n = 0; n < n_count; ++n) {
      cycle.push_back(OutputCoordinate{m, n_base + n});
    }
    cycles.push_back(std::move(cycle));
  }
  return cycles;
}

PostprocessScannerRef::PostprocessScannerRef(int m_count, int n_count,
                                             int n_lanes, int n_base)
    : schedule_(make_postprocess_scan_order(m_count, n_count, n_lanes,
                                            n_base)) {}

void PostprocessScannerRef::reset() { cycle_index_ = 0; }

std::optional<std::vector<OutputCoordinate>> PostprocessScannerRef::tick(
    bool ready) {
  if (done()) {
    return std::nullopt;
  }
  auto current = schedule_[cycle_index_];
  if (ready) {
    ++cycle_index_;
  }
  return current;
}

std::vector<DmaBurst> make_dma_bursts(std::uint64_t address,
                                      std::size_t byte_count,
                                      std::size_t beat_bytes,
                                      std::size_t max_burst_bytes) {
  constexpr std::uint64_t kPageBytes = 4096;
  if (byte_count == 0 || beat_bytes == 0 || max_burst_bytes == 0 ||
      address % beat_bytes != 0 || max_burst_bytes % beat_bytes != 0 ||
      kPageBytes % beat_bytes != 0 || max_burst_bytes > kPageBytes) {
    throw std::invalid_argument("invalid DMA burst geometry");
  }
  if (byte_count > std::numeric_limits<std::uint64_t>::max() - address) {
    throw std::overflow_error("DMA address range overflow");
  }

  std::vector<DmaBurst> bursts;
  std::size_t remaining = byte_count;
  std::uint64_t current = address;
  while (remaining != 0) {
    const std::size_t page_remaining = static_cast<std::size_t>(
        kPageBytes - (current & (kPageBytes - 1)));
    const std::size_t valid =
        std::min({remaining, max_burst_bytes, page_remaining});
    const std::size_t beats = (valid + beat_bytes - 1) / beat_bytes;
    bursts.push_back(DmaBurst{current, valid, beats});
    current += valid;
    remaining -= valid;
  }
  return bursts;
}

std::size_t PingPongTileBufferRef::checked_bank(int bank) {
  if (bank < 0 || bank >= 2) {
    throw std::out_of_range("ping-pong bank must be 0 or 1");
  }
  return static_cast<std::size_t>(bank);
}

void PingPongTileBufferRef::reset() {
  states_.fill(TileBankState::kEmpty);
  compute_bank_ = -1;
}

void PingPongTileBufferRef::begin_dma(int bank) {
  const std::size_t index = checked_bank(bank);
  if (states_[index] != TileBankState::kEmpty) {
    throw std::logic_error("DMA may only acquire an empty tile bank");
  }
  states_[index] = TileBankState::kDmaFill;
}

void PingPongTileBufferRef::complete_dma(int bank, bool success) {
  const std::size_t index = checked_bank(bank);
  if (states_[index] != TileBankState::kDmaFill) {
    throw std::logic_error("DMA completion without bank ownership");
  }
  states_[index] = success ? TileBankState::kReady : TileBankState::kEmpty;
}

void PingPongTileBufferRef::begin_compute(int bank) {
  const std::size_t index = checked_bank(bank);
  if (compute_bank_ != -1 || states_[index] != TileBankState::kReady) {
    throw std::logic_error("compute may only acquire one ready tile bank");
  }
  states_[index] = TileBankState::kCompute;
  compute_bank_ = bank;
}

void PingPongTileBufferRef::complete_compute(int bank) {
  const std::size_t index = checked_bank(bank);
  if (compute_bank_ != bank || states_[index] != TileBankState::kCompute) {
    throw std::logic_error("compute completion does not own this tile bank");
  }
  states_[index] = TileBankState::kEmpty;
  compute_bank_ = -1;
}

TileBankState PingPongTileBufferRef::state(int bank) const {
  return states_[checked_bank(bank)];
}

}  // namespace alexnet::golden

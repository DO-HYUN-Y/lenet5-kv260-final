#include "alexnet_golden/weight_tile_bank_ref.hpp"

#include <stdexcept>

namespace alexnet::golden {

N8WeightTileBankRef::N8WeightTileBankRef(std::size_t depth) : depth_(depth) {
  if (depth == 0) {
    throw std::invalid_argument("weight tile bank depth must be positive");
  }
  words_.reserve(depth);
}

void N8WeightTileBankRef::reset() {
  state_ = WeightTileBankState::kEmpty;
  k_count_ = 0;
  n_lane_mask_ = 0;
  context_tag_ = 0;
  completed_replays_ = 0;
  words_.clear();
}

void N8WeightTileBankRef::begin_fill(std::size_t k_count,
                                      std::uint8_t n_lane_mask,
                                      int context_tag) {
  if (state_ != WeightTileBankState::kEmpty) {
    throw std::logic_error("weight fill requires an empty bank");
  }
  if (k_count == 0 || k_count > depth_ || n_lane_mask == 0 ||
      context_tag < 0) {
    throw std::invalid_argument("invalid weight tile descriptor");
  }
  k_count_ = k_count;
  n_lane_mask_ = n_lane_mask;
  context_tag_ = context_tag;
  words_.clear();
  state_ = WeightTileBankState::kWriting;
}

void N8WeightTileBankRef::write(std::uint64_t values,
                                std::uint8_t n_lane_mask, bool last) {
  if (state_ != WeightTileBankState::kWriting ||
      n_lane_mask != n_lane_mask_ || words_.size() >= k_count_) {
    throw std::logic_error("weight write does not own this bank");
  }
  std::uint64_t masked = 0;
  for (int lane = 0; lane < 8; ++lane) {
    if ((n_lane_mask_ & (std::uint8_t{1} << lane)) != 0) {
      masked |= ((values >> (lane * 8)) & std::uint64_t{0xff}) << (lane * 8);
    }
  }
  words_.push_back(masked);
  const bool expected_last = words_.size() == k_count_;
  if (last != expected_last) {
    throw std::logic_error("weight write_last did not match K count");
  }
  if (expected_last) {
    state_ = WeightTileBankState::kReady;
  }
}

void N8WeightTileBankRef::begin_replay(std::size_t k_count,
                                       std::uint8_t n_lane_mask,
                                       int context_tag) {
  if (state_ != WeightTileBankState::kReady) {
    throw std::logic_error("weight replay requires a ready bank");
  }
  if (k_count != k_count_ || n_lane_mask != n_lane_mask_ ||
      context_tag != context_tag_) {
    throw std::invalid_argument("weight replay context mismatch");
  }
  state_ = WeightTileBankState::kReplaying;
}

WeightTileWord N8WeightTileBankRef::word(std::size_t k) const {
  if (state_ != WeightTileBankState::kReplaying || k >= k_count_) {
    throw std::logic_error("weight replay does not own this bank");
  }
  WeightTileWord result;
  result.k = k;
  result.last = k + 1 == k_count_;
  result.n_lane_mask = n_lane_mask_;
  result.context_tag = context_tag_;
  const std::uint64_t packed = words_.at(k);
  for (int lane = 0; lane < 8; ++lane) {
    result.values[static_cast<std::size_t>(lane)] = static_cast<std::int8_t>(
        (packed >> (lane * 8)) & std::uint64_t{0xff});
  }
  return result;
}

void N8WeightTileBankRef::complete_replay() {
  if (state_ != WeightTileBankState::kReplaying) {
    throw std::logic_error("weight replay completion without ownership");
  }
  ++completed_replays_;
  state_ = WeightTileBankState::kReady;
}

void N8WeightTileBankRef::release() {
  if (state_ != WeightTileBankState::kReady) {
    throw std::logic_error("weight release requires a ready bank");
  }
  state_ = WeightTileBankState::kEmpty;
  k_count_ = 0;
  n_lane_mask_ = 0;
  context_tag_ = 0;
  words_.clear();
}

}  // namespace alexnet::golden

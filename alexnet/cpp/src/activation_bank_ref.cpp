#include "alexnet_golden/activation_bank_ref.hpp"

#include <limits>
#include <stdexcept>

namespace alexnet::golden {

N8ActivationBankRef::N8ActivationBankRef(std::size_t depth) : depth_(depth) {
  if (depth == 0) {
    throw std::invalid_argument("activation bank depth must be positive");
  }
  words_.reserve(depth);
}

void N8ActivationBankRef::reset() {
  state_ = ActivationBankState::kEmpty;
  word_count_ = 0;
  lane_mask_ = 0;
  tensor_tag_ = 0;
  words_.clear();
}

void N8ActivationBankRef::begin_fill(std::size_t word_count,
                                     std::uint8_t lane_mask,
                                     int tensor_tag) {
  if (state_ != ActivationBankState::kEmpty) {
    throw std::logic_error("activation fill requires an empty bank");
  }
  if (word_count == 0 || word_count > depth_ || lane_mask == 0 ||
      tensor_tag < 0) {
    throw std::invalid_argument("invalid activation bank descriptor");
  }
  word_count_ = word_count;
  lane_mask_ = lane_mask;
  tensor_tag_ = tensor_tag;
  words_.clear();
  state_ = ActivationBankState::kWriting;
}

void N8ActivationBankRef::write(std::uint64_t values,
                                std::uint8_t lane_mask, bool last) {
  if (state_ != ActivationBankState::kWriting || lane_mask != lane_mask_ ||
      words_.size() >= word_count_) {
    throw std::logic_error("activation write does not own this bank");
  }
  std::uint64_t masked = 0;
  for (int lane = 0; lane < 8; ++lane) {
    if ((lane_mask_ & (std::uint8_t{1} << lane)) != 0) {
      masked |= ((values >> (lane * 8)) & std::uint64_t{0xff}) << (lane * 8);
    }
  }
  words_.push_back(masked);
  const bool expected_last = words_.size() == word_count_;
  if (last != expected_last) {
    throw std::logic_error("activation write_last did not match word_count");
  }
  if (expected_last) {
    state_ = ActivationBankState::kReady;
  }
}

void N8ActivationBankRef::begin_read() {
  if (state_ != ActivationBankState::kReady) {
    throw std::logic_error("activation read requires a ready bank");
  }
  state_ = ActivationBankState::kReading;
}

ActivationBankWord N8ActivationBankRef::word(std::size_t index) const {
  if (state_ != ActivationBankState::kReading || index >= word_count_) {
    throw std::logic_error("activation read does not own this bank");
  }
  ActivationBankWord result;
  result.index = index;
  result.last = index + 1 == word_count_;
  result.lane_mask = lane_mask_;
  result.tensor_tag = tensor_tag_;
  const std::uint64_t packed = words_.at(index);
  for (int lane = 0; lane < 8; ++lane) {
    result.values[static_cast<std::size_t>(lane)] = static_cast<std::int8_t>(
        (packed >> (lane * 8)) & std::uint64_t{0xff});
  }
  return result;
}

void N8ActivationBankRef::complete_read() {
  if (state_ != ActivationBankState::kReading) {
    throw std::logic_error("activation read completion without ownership");
  }
  reset();
}

}  // namespace alexnet::golden

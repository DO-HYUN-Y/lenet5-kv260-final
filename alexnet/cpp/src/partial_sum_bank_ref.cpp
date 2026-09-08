#include "alexnet_golden/partial_sum_bank_ref.hpp"

#include <limits>
#include <stdexcept>

namespace alexnet::golden {

N8Int32PartialSumBankRef::N8Int32PartialSumBankRef(std::size_t depth)
    : depth_(depth) {
  if (depth == 0) {
    throw std::invalid_argument("partial-sum bank depth must be positive");
  }
  words_.reserve(depth);
}

void N8Int32PartialSumBankRef::reset() {
  state_ = PartialSumBankState::kEmpty;
  word_count_ = 0;
  n_lane_mask_ = 0;
  context_tag_ = 0;
  words_accepted_ = 0;
  next_chunk_index_ = 0;
  completed_chunks_ = 0;
  current_first_chunk_ = false;
  current_final_chunk_ = false;
  words_.clear();
}

void N8Int32PartialSumBankRef::begin_chunk(
    std::size_t word_count, std::uint8_t n_lane_mask, int context_tag,
    std::size_t chunk_index, bool first_chunk, bool final_chunk) {
  if (word_count == 0 || word_count > depth_ || n_lane_mask == 0 ||
      context_tag < 0) {
    throw std::invalid_argument("invalid partial-sum chunk descriptor");
  }

  if (state_ == PartialSumBankState::kEmpty) {
    if (!first_chunk || chunk_index != 0) {
      throw std::invalid_argument("partial-sum transaction must start at chunk zero");
    }
    word_count_ = word_count;
    n_lane_mask_ = n_lane_mask;
    context_tag_ = context_tag;
    next_chunk_index_ = 1;
    completed_chunks_ = 0;
    words_.assign(word_count_, {});
    state_ = PartialSumBankState::kIngestFirst;
  } else if (state_ == PartialSumBankState::kReady) {
    if (first_chunk || word_count != word_count_ ||
        n_lane_mask != n_lane_mask_ || context_tag != context_tag_ ||
        chunk_index != next_chunk_index_) {
      throw std::invalid_argument("partial-sum continuation context mismatch");
    }
    state_ = PartialSumBankState::kIngestAccum;
  } else {
    throw std::logic_error("partial-sum descriptor does not own the bank");
  }

  words_accepted_ = 0;
  current_first_chunk_ = first_chunk;
  current_final_chunk_ = final_chunk;
}

void N8Int32PartialSumBankRef::write(
    std::size_t index, const std::array<std::int32_t, 8>& accumulators,
    std::uint8_t n_lane_mask, bool last) {
  if ((state_ != PartialSumBankState::kIngestFirst &&
       state_ != PartialSumBankState::kIngestAccum) ||
      index != words_accepted_ || index >= word_count_ ||
      n_lane_mask != n_lane_mask_) {
    throw std::logic_error("partial-sum word does not match active chunk");
  }
  if (last != (index + 1 == word_count_)) {
    throw std::logic_error("partial-sum last did not match word count");
  }

  for (int lane = 0; lane < 8; ++lane) {
    const auto lane_index = static_cast<std::size_t>(lane);
    if ((n_lane_mask_ & (std::uint8_t{1} << lane)) == 0) {
      words_[index][lane_index] = 0;
    } else if (current_first_chunk_) {
      words_[index][lane_index] = accumulators[lane_index];
    } else {
      const std::int64_t sum =
          static_cast<std::int64_t>(words_[index][lane_index]) +
          static_cast<std::int64_t>(accumulators[lane_index]);
      if (sum < std::numeric_limits<std::int32_t>::min() ||
          sum > std::numeric_limits<std::int32_t>::max()) {
        throw std::overflow_error("partial-sum accumulation exceeded INT32");
      }
      words_[index][lane_index] = static_cast<std::int32_t>(sum);
    }
  }

  ++words_accepted_;
  if (last) {
    ++completed_chunks_;
    if (!current_first_chunk_) {
      ++next_chunk_index_;
    }
    state_ = current_final_chunk_ ? PartialSumBankState::kEmitting
                                  : PartialSumBankState::kReady;
  }
}

PartialSumWord N8Int32PartialSumBankRef::word(std::size_t index) const {
  if (state_ != PartialSumBankState::kEmitting || index >= word_count_) {
    throw std::logic_error("partial-sum output does not own the bank");
  }
  return PartialSumWord{index, index + 1 == word_count_, n_lane_mask_,
                        context_tag_, words_.at(index)};
}

void N8Int32PartialSumBankRef::complete_emit() {
  if (state_ != PartialSumBankState::kEmitting) {
    throw std::logic_error("partial-sum emit completion without ownership");
  }
  reset();
}

}  // namespace alexnet::golden

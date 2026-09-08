#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace alexnet::golden {

enum class PartialSumBankState : std::uint8_t {
  kEmpty = 0,
  kIngestFirst = 1,
  kReady = 2,
  kIngestAccum = 3,
  kEmitting = 4,
};

struct PartialSumWord {
  std::size_t index = 0;
  bool last = false;
  std::uint8_t n_lane_mask = 0;
  int context_tag = 0;
  std::array<std::int32_t, 8> accumulators{};
};

// Transaction oracle for one N8 x INT32 partial-sum bank. The first channel
// chunk replaces storage, continuation chunks add in signed INT32 precision,
// and output ownership begins only after the final chunk is complete.
class N8Int32PartialSumBankRef {
 public:
  explicit N8Int32PartialSumBankRef(std::size_t depth = 512);

  void reset();
  void begin_chunk(std::size_t word_count, std::uint8_t n_lane_mask,
                   int context_tag, std::size_t chunk_index,
                   bool first_chunk, bool final_chunk);
  void write(std::size_t index,
             const std::array<std::int32_t, 8>& accumulators,
             std::uint8_t n_lane_mask, bool last);
  PartialSumWord word(std::size_t index) const;
  void complete_emit();

  PartialSumBankState state() const { return state_; }
  std::size_t depth() const { return depth_; }
  std::size_t word_count() const { return word_count_; }
  std::size_t words_accepted() const { return words_accepted_; }
  std::size_t next_chunk_index() const { return next_chunk_index_; }
  std::size_t completed_chunks() const { return completed_chunks_; }

 private:
  std::size_t depth_ = 0;
  PartialSumBankState state_ = PartialSumBankState::kEmpty;
  std::size_t word_count_ = 0;
  std::uint8_t n_lane_mask_ = 0;
  int context_tag_ = 0;
  std::size_t words_accepted_ = 0;
  std::size_t next_chunk_index_ = 0;
  std::size_t completed_chunks_ = 0;
  bool current_first_chunk_ = false;
  bool current_final_chunk_ = false;
  std::vector<std::array<std::int32_t, 8>> words_;
};

}  // namespace alexnet::golden

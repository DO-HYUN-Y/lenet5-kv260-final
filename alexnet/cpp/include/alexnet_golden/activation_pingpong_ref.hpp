#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <deque>

#include "alexnet_golden/activation_bank_ref.hpp"

namespace alexnet::golden {

// Transaction-level ownership and ordering oracle for two independent N8
// activation banks. The data behavior remains delegated to the measured
// single-bank reference.
class N8ActivationPingPongRef {
 public:
  explicit N8ActivationPingPongRef(std::size_t depth = 512);

  void reset();
  int begin_fill(bool is_pooled, std::size_t word_count,
                 std::uint8_t lane_mask, int tensor_tag);
  void write(bool is_pooled, std::uint64_t values,
             std::uint8_t lane_mask, bool last);
  int begin_read(int tensor_tag);
  ActivationBankWord word(std::size_t index) const;
  void complete_read();

  const N8ActivationBankRef& bank(int index) const;
  std::size_t ready_count() const { return ready_banks_.size(); }
  int ready_head_bank() const;
  int ready_head_tag() const;
  int fill_bank() const { return fill_bank_; }
  int read_bank() const { return read_bank_; }
  bool fill_is_pooled() const { return fill_is_pooled_; }

 private:
  std::array<N8ActivationBankRef, 2> banks_;
  std::array<int, 2> tensor_tags_{};
  std::deque<int> ready_banks_;
  int fill_preference_ = 0;
  int fill_bank_ = -1;
  int read_bank_ = -1;
  bool fill_is_pooled_ = false;
};

// Two segmented ping-pong units form logical A/B tensors with twice the
// physical-bank depth. Segment descriptors and read starts remain atomic;
// data crosses the fixed segment boundary in global sequential order.
class N8ActivationDualSegmentPingPongRef {
 public:
  explicit N8ActivationDualSegmentPingPongRef(std::size_t segment_depth = 512);

  void reset();
  int begin_fill(bool is_pooled, std::size_t word_count,
                 std::uint8_t lane_mask, int tensor_tag);
  void write(bool is_pooled, std::uint64_t values,
             std::uint8_t lane_mask, bool last);
  int begin_read(int tensor_tag);
  ActivationBankWord word(std::size_t global_index) const;
  void complete_segment0_read();
  void complete_read();

  std::size_t ready_count() const;
  int ready_head_bank() const;
  int ready_head_tag() const;
  int fill_bank() const { return fill_bank_; }
  int read_bank() const { return read_bank_; }
  bool fill_is_pooled() const { return fill_is_pooled_; }
  int read_segment() const { return read_segment_; }

 private:
  std::size_t segment_depth_ = 0;
  std::array<N8ActivationPingPongRef, 2> segments_;
  std::size_t fill_word_count_ = 0;
  std::size_t fill_index_ = 0;
  bool fill_replicated_ = false;
  std::deque<bool> ready_replicated_;
  int fill_bank_ = -1;
  int read_bank_ = -1;
  int read_segment_ = -1;
  bool read_replicated_ = false;
  bool fill_is_pooled_ = false;
};

}  // namespace alexnet::golden

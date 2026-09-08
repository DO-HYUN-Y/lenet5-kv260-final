#include "alexnet_golden/activation_pingpong_ref.hpp"

#include <algorithm>
#include <stdexcept>

namespace alexnet::golden {

N8ActivationPingPongRef::N8ActivationPingPongRef(std::size_t depth)
    : banks_{N8ActivationBankRef(depth), N8ActivationBankRef(depth)} {
  reset();
}

void N8ActivationPingPongRef::reset() {
  for (auto& bank_ref : banks_) {
    bank_ref.reset();
  }
  tensor_tags_.fill(0);
  ready_banks_.clear();
  fill_preference_ = 0;
  fill_bank_ = -1;
  read_bank_ = -1;
  fill_is_pooled_ = false;
}

int N8ActivationPingPongRef::begin_fill(bool is_pooled,
                                        std::size_t word_count,
                                        std::uint8_t lane_mask,
                                        int tensor_tag) {
  if (fill_bank_ >= 0) {
    throw std::logic_error("activation ping-pong already has a fill owner");
  }
  int selected = fill_preference_;
  if (banks_[static_cast<std::size_t>(selected)].state() !=
      ActivationBankState::kEmpty) {
    selected ^= 1;
  }
  if (banks_[static_cast<std::size_t>(selected)].state() !=
      ActivationBankState::kEmpty) {
    throw std::logic_error("activation ping-pong has no empty fill bank");
  }
  banks_[static_cast<std::size_t>(selected)].begin_fill(
      word_count, lane_mask, tensor_tag);
  tensor_tags_[static_cast<std::size_t>(selected)] = tensor_tag;
  fill_bank_ = selected;
  fill_preference_ = selected ^ 1;
  fill_is_pooled_ = is_pooled;
  return selected;
}

void N8ActivationPingPongRef::write(bool is_pooled, std::uint64_t values,
                                    std::uint8_t lane_mask, bool last) {
  if (fill_bank_ < 0 || is_pooled != fill_is_pooled_) {
    throw std::logic_error("activation ping-pong write source lost ownership");
  }
  const int selected = fill_bank_;
  banks_[static_cast<std::size_t>(selected)].write(values, lane_mask, last);
  if (last) {
    ready_banks_.push_back(selected);
    fill_bank_ = -1;
  }
}

int N8ActivationPingPongRef::begin_read(int tensor_tag) {
  if (read_bank_ >= 0 || ready_banks_.empty()) {
    throw std::logic_error("activation ping-pong has no readable head");
  }
  const int selected = ready_banks_.front();
  if (tensor_tags_[static_cast<std::size_t>(selected)] != tensor_tag) {
    throw std::logic_error("activation ping-pong tensor tag mismatch");
  }
  ready_banks_.pop_front();
  banks_[static_cast<std::size_t>(selected)].begin_read();
  read_bank_ = selected;
  return selected;
}

ActivationBankWord N8ActivationPingPongRef::word(std::size_t index) const {
  if (read_bank_ < 0) {
    throw std::logic_error("activation ping-pong has no active reader");
  }
  return banks_[static_cast<std::size_t>(read_bank_)].word(index);
}

void N8ActivationPingPongRef::complete_read() {
  if (read_bank_ < 0) {
    throw std::logic_error("activation ping-pong read completion has no owner");
  }
  banks_[static_cast<std::size_t>(read_bank_)].complete_read();
  read_bank_ = -1;
}

const N8ActivationBankRef& N8ActivationPingPongRef::bank(int index) const {
  if (index < 0 || index > 1) {
    throw std::out_of_range("activation ping-pong bank index is invalid");
  }
  return banks_[static_cast<std::size_t>(index)];
}

int N8ActivationPingPongRef::ready_head_bank() const {
  return ready_banks_.empty() ? -1 : ready_banks_.front();
}

int N8ActivationPingPongRef::ready_head_tag() const {
  if (ready_banks_.empty()) {
    return 0;
  }
  return tensor_tags_[static_cast<std::size_t>(ready_banks_.front())];
}

N8ActivationDualSegmentPingPongRef::N8ActivationDualSegmentPingPongRef(
    std::size_t segment_depth)
    : segment_depth_(segment_depth),
      segments_{N8ActivationPingPongRef(segment_depth),
                N8ActivationPingPongRef(segment_depth)} {
  if (segment_depth < 2) {
    throw std::invalid_argument("dual-segment activation depth is invalid");
  }
  reset();
}

void N8ActivationDualSegmentPingPongRef::reset() {
  for (auto& segment : segments_) {
    segment.reset();
  }
  fill_word_count_ = 0;
  fill_index_ = 0;
  fill_replicated_ = false;
  ready_replicated_.clear();
  fill_bank_ = -1;
  read_bank_ = -1;
  read_segment_ = -1;
  read_replicated_ = false;
  fill_is_pooled_ = false;
}

int N8ActivationDualSegmentPingPongRef::begin_fill(
    bool is_pooled, std::size_t word_count, std::uint8_t lane_mask,
    int tensor_tag) {
  if (fill_bank_ >= 0 || word_count == 0 ||
      word_count > 2 * segment_depth_) {
    throw std::logic_error("dual-segment activation fill is invalid");
  }
  fill_replicated_ = word_count <= segment_depth_;
  const std::size_t segment0_words =
      fill_replicated_ ? word_count : segment_depth_;
  const std::size_t segment1_words =
      fill_replicated_ ? word_count : word_count - segment_depth_;
  const int segment0_bank = segments_[0].begin_fill(
      is_pooled, segment0_words, lane_mask, tensor_tag);
  const int segment1_bank = segments_[1].begin_fill(
      is_pooled, segment1_words, lane_mask, tensor_tag);
  if (segment0_bank != segment1_bank) {
    throw std::logic_error("dual-segment activation fill banks diverged");
  }
  fill_word_count_ = word_count;
  fill_index_ = 0;
  fill_bank_ = segment0_bank;
  fill_is_pooled_ = is_pooled;
  return fill_bank_;
}

void N8ActivationDualSegmentPingPongRef::write(
    bool is_pooled, std::uint64_t values, std::uint8_t lane_mask,
    bool last) {
  if (fill_bank_ < 0 || is_pooled != fill_is_pooled_ ||
      fill_index_ >= fill_word_count_ ||
      last != (fill_index_ + 1 == fill_word_count_)) {
    throw std::logic_error("dual-segment activation write lost ownership");
  }
  if (fill_replicated_) {
    segments_[0].write(is_pooled, values, lane_mask, last);
    segments_[1].write(is_pooled, values, lane_mask, last);
  } else {
    const std::size_t segment = fill_index_ >= segment_depth_ ? 1 : 0;
    const bool local_last = segment == 0
                                ? fill_index_ + 1 == segment_depth_
                                : last;
    segments_[segment].write(is_pooled, values, lane_mask, local_last);
  }
  ++fill_index_;
  if (last) {
    ready_replicated_.push_back(fill_replicated_);
    fill_bank_ = -1;
  }
}

int N8ActivationDualSegmentPingPongRef::begin_read(int tensor_tag) {
  if (read_bank_ >= 0 || ready_count() == 0 ||
      ready_replicated_.empty()) {
    throw std::logic_error("dual-segment activation has no readable tensor");
  }
  const int segment0_bank = segments_[0].begin_read(tensor_tag);
  const int segment1_bank = segments_[1].begin_read(tensor_tag);
  if (segment0_bank != segment1_bank) {
    throw std::logic_error("dual-segment activation read banks diverged");
  }
  read_bank_ = segment0_bank;
  read_segment_ = 0;
  read_replicated_ = ready_replicated_.front();
  ready_replicated_.pop_front();
  return read_bank_;
}

ActivationBankWord N8ActivationDualSegmentPingPongRef::word(
    std::size_t global_index) const {
  if (read_bank_ < 0 || global_index >= 2 * segment_depth_) {
    throw std::logic_error("dual-segment activation read index is invalid");
  }
  if (read_replicated_) {
    return segments_[0].word(global_index);
  }
  if (global_index < segment_depth_) {
    auto result = segments_[0].word(global_index);
    result.last = false;
    return result;
  }
  auto result = segments_[1].word(global_index - segment_depth_);
  result.index = global_index;
  return result;
}

void N8ActivationDualSegmentPingPongRef::complete_segment0_read() {
  if (read_bank_ < 0 || read_segment_ != 0 || read_replicated_) {
    throw std::logic_error("dual-segment activation segment-0 completion invalid");
  }
  segments_[0].complete_read();
  read_segment_ = 1;
}

void N8ActivationDualSegmentPingPongRef::complete_read() {
  if (read_bank_ < 0 ||
      (read_replicated_ ? read_segment_ != 0 : read_segment_ != 1)) {
    throw std::logic_error("dual-segment activation completion invalid");
  }
  if (read_replicated_)
    segments_[0].complete_read();
  segments_[1].complete_read();
  read_bank_ = -1;
  read_segment_ = -1;
  read_replicated_ = false;
}

std::size_t N8ActivationDualSegmentPingPongRef::ready_count() const {
  return std::min(segments_[0].ready_count(), segments_[1].ready_count());
}

int N8ActivationDualSegmentPingPongRef::ready_head_bank() const {
  if (ready_count() == 0) {
    return -1;
  }
  const int segment0_bank = segments_[0].ready_head_bank();
  const int segment1_bank = segments_[1].ready_head_bank();
  if (segment0_bank != segment1_bank) {
    throw std::logic_error("dual-segment activation READY banks diverged");
  }
  return segment0_bank;
}

int N8ActivationDualSegmentPingPongRef::ready_head_tag() const {
  if (ready_count() == 0) {
    return 0;
  }
  const int segment0_tag = segments_[0].ready_head_tag();
  const int segment1_tag = segments_[1].ready_head_tag();
  if (segment0_tag != segment1_tag) {
    throw std::logic_error("dual-segment activation READY tags diverged");
  }
  return segment0_tag;
}

}  // namespace alexnet::golden

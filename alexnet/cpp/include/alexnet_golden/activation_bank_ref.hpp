#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace alexnet::golden {

enum class ActivationBankState : std::uint8_t {
  kEmpty = 0,
  kWriting = 1,
  kReady = 2,
  kReading = 3,
};

struct ActivationBankWord {
  std::size_t index = 0;
  bool last = false;
  std::uint8_t lane_mask = 0;
  int tensor_tag = 0;
  std::array<std::int8_t, 8> values{};
};

// Transaction-level oracle for one physical N8 activation bank. Larger tensor
// stores cascade this unit; A/B overlap is formed by instantiating independent
// banks and never reading and writing the same instance concurrently.
class N8ActivationBankRef {
 public:
  explicit N8ActivationBankRef(std::size_t depth = 512);

  void reset();
  void begin_fill(std::size_t word_count, std::uint8_t lane_mask,
                  int tensor_tag);
  void write(std::uint64_t values, std::uint8_t lane_mask, bool last);
  void begin_read();
  ActivationBankWord word(std::size_t index) const;
  void complete_read();

  ActivationBankState state() const { return state_; }
  std::size_t depth() const { return depth_; }
  std::size_t word_count() const { return word_count_; }
  std::size_t words_written() const { return words_.size(); }

 private:
  std::size_t depth_ = 0;
  ActivationBankState state_ = ActivationBankState::kEmpty;
  std::size_t word_count_ = 0;
  std::uint8_t lane_mask_ = 0;
  int tensor_tag_ = 0;
  std::vector<std::uint64_t> words_;
};

}  // namespace alexnet::golden

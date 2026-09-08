#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace alexnet::golden {

enum class WeightTileBankState : std::uint8_t {
  kEmpty = 0,
  kWriting = 1,
  kReady = 2,
  kReplaying = 3,
};

struct WeightTileWord {
  std::size_t k = 0;
  bool last = false;
  std::uint8_t n_lane_mask = 0;
  int context_tag = 0;
  std::array<std::int8_t, 8> values{};
};

// Transaction-level oracle for one resident N8 weight tile. Unlike an
// activation bank read, replay completion retains the tile and rewinds K for
// another spatial M group. Explicit release returns ownership to the filler.
class N8WeightTileBankRef {
 public:
  explicit N8WeightTileBankRef(std::size_t depth = 968);

  void reset();
  void begin_fill(std::size_t k_count, std::uint8_t n_lane_mask,
                  int context_tag);
  void write(std::uint64_t values, std::uint8_t n_lane_mask, bool last);
  void begin_replay(std::size_t k_count, std::uint8_t n_lane_mask,
                    int context_tag);
  WeightTileWord word(std::size_t k) const;
  void complete_replay();
  void release();

  WeightTileBankState state() const { return state_; }
  std::size_t depth() const { return depth_; }
  std::size_t k_count() const { return k_count_; }
  std::size_t words_written() const { return words_.size(); }
  std::size_t completed_replays() const { return completed_replays_; }

 private:
  std::size_t depth_ = 0;
  WeightTileBankState state_ = WeightTileBankState::kEmpty;
  std::size_t k_count_ = 0;
  std::uint8_t n_lane_mask_ = 0;
  int context_tag_ = 0;
  std::size_t completed_replays_ = 0;
  std::vector<std::uint64_t> words_;
};

}  // namespace alexnet::golden

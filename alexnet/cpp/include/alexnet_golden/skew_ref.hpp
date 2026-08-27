#pragma once

#include <cstdint>
#include <deque>
#include <vector>

namespace alexnet::golden {

struct ActivationPairToken {
  std::int8_t lo = 0;
  std::int8_t hi = 0;
  bool valid = false;
  std::uint8_t lane_mask = 0;
  bool reduce_last = false;
  int k_tag = 0;
  int tile_tag = 0;
};

struct WeightToken {
  std::int8_t value = 0;
  bool valid = false;
  bool reduce_last = false;
  int k_tag = 0;
  int tile_tag = 0;
};

struct SkewInputs {
  std::vector<ActivationPairToken> activations;
  std::vector<WeightToken> weights;
};

using SkewOutputs = SkewInputs;

// tick() returns values visible in the current cycle before the active edge,
// then captures inputs when enable is true. Delay-zero paths are wires.
class LocalSkewRef {
 public:
  explicit LocalSkewRef(int activation_groups = 4, int weight_columns = 8);
  void reset();
  SkewOutputs tick(bool enable, const SkewInputs& inputs);

  int activation_groups() const { return activation_groups_; }
  int weight_columns() const { return weight_columns_; }

 private:
  int activation_groups_;
  int weight_columns_;
  std::vector<std::deque<ActivationPairToken>> activation_delay_;
  std::vector<std::deque<WeightToken>> weight_delay_;
};

int activation_arrival_cycle(int issue_cycle, int activation_group);
int weight_arrival_cycle(int issue_cycle, int weight_column);
int pe_alignment_cycle(int issue_cycle, int k, int activation_group,
                       int weight_column);

}  // namespace alexnet::golden

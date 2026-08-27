#include "alexnet_golden/skew_ref.hpp"

#include <stdexcept>

namespace alexnet::golden {

LocalSkewRef::LocalSkewRef(int activation_groups, int weight_columns)
    : activation_groups_(activation_groups), weight_columns_(weight_columns) {
  if (activation_groups <= 0 || weight_columns <= 0) {
    throw std::invalid_argument("local skew dimensions must be positive");
  }
  reset();
}

void LocalSkewRef::reset() {
  activation_delay_.assign(static_cast<std::size_t>(activation_groups_), {});
  weight_delay_.assign(static_cast<std::size_t>(weight_columns_), {});
  for (int group = 1; group < activation_groups_; ++group) {
    activation_delay_[static_cast<std::size_t>(group)].assign(
        static_cast<std::size_t>(group), ActivationPairToken{});
  }
  for (int column = 1; column < weight_columns_; ++column) {
    weight_delay_[static_cast<std::size_t>(column)].assign(
        static_cast<std::size_t>(column), WeightToken{});
  }
}

SkewOutputs LocalSkewRef::tick(bool enable, const SkewInputs& inputs) {
  if (inputs.activations.size() != static_cast<std::size_t>(activation_groups_) ||
      inputs.weights.size() != static_cast<std::size_t>(weight_columns_)) {
    throw std::invalid_argument("local skew input vector size mismatch");
  }

  SkewOutputs outputs;
  outputs.activations.resize(static_cast<std::size_t>(activation_groups_));
  outputs.weights.resize(static_cast<std::size_t>(weight_columns_));

  outputs.activations[0] = inputs.activations[0];
  for (int group = 1; group < activation_groups_; ++group) {
    auto& delay = activation_delay_[static_cast<std::size_t>(group)];
    outputs.activations[static_cast<std::size_t>(group)] = delay.front();
    if (enable) {
      delay.pop_front();
      delay.push_back(inputs.activations[static_cast<std::size_t>(group)]);
    }
  }

  outputs.weights[0] = inputs.weights[0];
  for (int column = 1; column < weight_columns_; ++column) {
    auto& delay = weight_delay_[static_cast<std::size_t>(column)];
    outputs.weights[static_cast<std::size_t>(column)] = delay.front();
    if (enable) {
      delay.pop_front();
      delay.push_back(inputs.weights[static_cast<std::size_t>(column)]);
    }
  }
  return outputs;
}

int activation_arrival_cycle(int issue_cycle, int activation_group) {
  if (activation_group < 0) {
    throw std::invalid_argument("activation group must be non-negative");
  }
  return issue_cycle + activation_group;
}

int weight_arrival_cycle(int issue_cycle, int weight_column) {
  if (weight_column < 0) {
    throw std::invalid_argument("weight column must be non-negative");
  }
  return issue_cycle + weight_column;
}

int pe_alignment_cycle(int issue_cycle, int k, int activation_group,
                       int weight_column) {
  if (k < 0 || activation_group < 0 || weight_column < 0) {
    throw std::invalid_argument("alignment indices must be non-negative");
  }
  return issue_cycle + k + activation_group + weight_column;
}

}  // namespace alexnet::golden

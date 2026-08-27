#pragma once

#include "alexnet_golden/tensor.hpp"

namespace alexnet::golden {

struct MaxPoolConfig {
  int kernel_h = 3;
  int kernel_w = 3;
  int stride_h = 2;
  int stride_w = 2;
  int pad_h = 0;
  int pad_w = 0;
};

TensorI8 maxpool2d(const TensorI8& input, const MaxPoolConfig& config);

}  // namespace alexnet::golden

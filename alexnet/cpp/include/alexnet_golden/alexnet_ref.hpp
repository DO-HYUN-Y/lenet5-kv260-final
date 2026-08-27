#pragma once

#include <vector>

#include "alexnet_golden/conv2d_ref.hpp"
#include "alexnet_golden/linear_ref.hpp"
#include "alexnet_golden/maxpool_ref.hpp"

namespace alexnet::golden {

struct ConvLayerRef {
  ConvWeightsI8 weights;
  Conv2DConfig config;
  std::vector<RequantParams> quant;
};

struct LinearLayerRef {
  MatrixI8 weights;
  std::vector<RequantParams> quant;
};

struct AlexNetInt8Parameters {
  ConvLayerRef conv1;
  ConvLayerRef conv2;
  ConvLayerRef conv3;
  ConvLayerRef conv4;
  ConvLayerRef conv5;
  LinearLayerRef fc6;
  LinearLayerRef fc7;
  LinearLayerRef fc8;
};

struct AlexNetInt8Outputs {
  TensorI8 conv1;
  TensorI8 pool1;
  TensorI8 conv2;
  TensorI8 pool2;
  TensorI8 conv3;
  TensorI8 conv4;
  TensorI8 conv5;
  TensorI8 pool5;
  MatrixI8 fc6;
  MatrixI8 fc7;
  MatrixI8 logits;
};

MatrixI8 flatten_nchw(const TensorI8& input);
AlexNetInt8Outputs run_alexnet_int8(const TensorI8& input,
                                    const AlexNetInt8Parameters& parameters);

}  // namespace alexnet::golden

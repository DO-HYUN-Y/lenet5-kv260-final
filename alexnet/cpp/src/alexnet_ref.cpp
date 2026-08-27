#include "alexnet_golden/alexnet_ref.hpp"

#include <stdexcept>

namespace alexnet::golden {

MatrixI8 flatten_nchw(const TensorI8& input) {
  MatrixI8 output(input.n(), input.c() * input.h() * input.w());
  for (int n = 0; n < input.n(); ++n) {
    int feature = 0;
    for (int c = 0; c < input.c(); ++c) {
      for (int y = 0; y < input.h(); ++y) {
        for (int x = 0; x < input.w(); ++x) {
          output.at(n, feature++) = input.at(n, c, y, x);
        }
      }
    }
  }
  return output;
}

AlexNetInt8Outputs run_alexnet_int8(
    const TensorI8& input, const AlexNetInt8Parameters& parameters) {
  AlexNetInt8Outputs outputs;
  const MaxPoolConfig pool{3, 3, 2, 2, 0, 0};

  outputs.conv1 = conv2d(input, parameters.conv1.weights,
                         parameters.conv1.config, parameters.conv1.quant);
  outputs.pool1 = maxpool2d(outputs.conv1, pool);
  outputs.conv2 = conv2d(outputs.pool1, parameters.conv2.weights,
                         parameters.conv2.config, parameters.conv2.quant);
  outputs.pool2 = maxpool2d(outputs.conv2, pool);
  outputs.conv3 = conv2d(outputs.pool2, parameters.conv3.weights,
                         parameters.conv3.config, parameters.conv3.quant);
  outputs.conv4 = conv2d(outputs.conv3, parameters.conv4.weights,
                         parameters.conv4.config, parameters.conv4.quant);
  outputs.conv5 = conv2d(outputs.conv4, parameters.conv5.weights,
                         parameters.conv5.config, parameters.conv5.quant);
  outputs.pool5 = maxpool2d(outputs.conv5, pool);

  MatrixI8 flattened = flatten_nchw(outputs.pool5);
  if (flattened.cols() != parameters.fc6.weights.cols()) {
    throw std::invalid_argument("pool5 flattened size does not match FC6 input");
  }
  outputs.fc6 = linear(flattened, parameters.fc6.weights, parameters.fc6.quant);
  outputs.fc7 = linear(outputs.fc6, parameters.fc7.weights, parameters.fc7.quant);
  outputs.logits = linear(outputs.fc7, parameters.fc8.weights, parameters.fc8.quant);
  return outputs;
}

}  // namespace alexnet::golden

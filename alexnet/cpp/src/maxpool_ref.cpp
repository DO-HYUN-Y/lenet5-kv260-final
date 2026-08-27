#include "alexnet_golden/maxpool_ref.hpp"

#include <algorithm>
#include <limits>
#include <stdexcept>

#include "alexnet_golden/window_ref.hpp"

namespace alexnet::golden {

TensorI8 maxpool2d(const TensorI8& input, const MaxPoolConfig& config) {
  const int output_h = conv_output_dim(input.h(), config.kernel_h,
                                       config.stride_h, config.pad_h);
  const int output_w = conv_output_dim(input.w(), config.kernel_w,
                                       config.stride_w, config.pad_w);
  TensorI8 output(input.n(), input.c(), output_h, output_w);

  for (int n = 0; n < input.n(); ++n) {
    for (int c = 0; c < input.c(); ++c) {
      for (int oy = 0; oy < output_h; ++oy) {
        for (int ox = 0; ox < output_w; ++ox) {
          std::int8_t maximum = std::numeric_limits<std::int8_t>::min();
          bool saw_input = false;
          for (int ky = 0; ky < config.kernel_h; ++ky) {
            const int iy = oy * config.stride_h - config.pad_h + ky;
            for (int kx = 0; kx < config.kernel_w; ++kx) {
              const int ix = ox * config.stride_w - config.pad_w + kx;
              if (iy < 0 || iy >= input.h() || ix < 0 || ix >= input.w()) {
                continue;
              }
              maximum = std::max(maximum, input.at(n, c, iy, ix));
              saw_input = true;
            }
          }
          if (!saw_input) {
            throw std::invalid_argument("max-pool window contains no input elements");
          }
          output.at(n, c, oy, ox) = maximum;
        }
      }
    }
  }
  return output;
}

}  // namespace alexnet::golden

#include "alexnet_golden/conv2d_ref.hpp"

#include <limits>
#include <stdexcept>

namespace alexnet::golden {
namespace {

std::size_t weight_offset(const ConvWeightsI8& weights, int oc, int ic,
                          int ky, int kx) {
  return (((static_cast<std::size_t>(oc) * weights.input_channels_per_group + ic) *
           weights.kernel_h + ky) *
          weights.kernel_w + kx);
}

std::int32_t checked_accumulator(std::int64_t value) {
  if (value < std::numeric_limits<std::int32_t>::min() ||
      value > std::numeric_limits<std::int32_t>::max()) {
    throw std::overflow_error("Conv2D INT32 accumulator overflow");
  }
  return static_cast<std::int32_t>(value);
}

}  // namespace

void ConvWeightsI8::validate() const {
  if (output_channels <= 0 || input_channels_per_group <= 0 || kernel_h <= 0 ||
      kernel_w <= 0) {
    throw std::invalid_argument("invalid OIHW convolution weight shape");
  }
  const std::size_t expected =
      static_cast<std::size_t>(output_channels) * input_channels_per_group *
      kernel_h * kernel_w;
  if (values.size() != expected) {
    throw std::invalid_argument("convolution weight data size does not match OIHW shape");
  }
}

std::int8_t ConvWeightsI8::at(int output_channel,
                              int input_channel_in_group, int kernel_y,
                              int kernel_x) const {
  if (output_channel < 0 || output_channel >= output_channels ||
      input_channel_in_group < 0 ||
      input_channel_in_group >= input_channels_per_group || kernel_y < 0 ||
      kernel_y >= kernel_h || kernel_x < 0 || kernel_x >= kernel_w) {
    throw std::out_of_range("convolution OIHW weight index out of range");
  }
  return values.at(weight_offset(*this, output_channel, input_channel_in_group,
                                 kernel_y, kernel_x));
}

TensorI32 conv2d_accumulate(const TensorI8& input,
                            const ConvWeightsI8& weights,
                            const Conv2DConfig& config) {
  weights.validate();
  if (config.groups <= 0 || input.c() % config.groups != 0 ||
      weights.output_channels % config.groups != 0) {
    throw std::invalid_argument("Conv2D groups must divide input and output channels");
  }
  if (input.c() / config.groups != weights.input_channels_per_group) {
    throw std::invalid_argument("Conv2D input channels per group do not match weights");
  }
  if (weights.kernel_h != config.geometry.kernel_h ||
      weights.kernel_w != config.geometry.kernel_w) {
    throw std::invalid_argument("Conv2D geometry kernel does not match weights");
  }

  const int output_h = conv_output_dim(input.h(), weights.kernel_h,
                                       config.geometry.stride_h,
                                       config.geometry.pad_h,
                                       config.geometry.dilation_h);
  const int output_w = conv_output_dim(input.w(), weights.kernel_w,
                                       config.geometry.stride_w,
                                       config.geometry.pad_w,
                                       config.geometry.dilation_w);
  TensorI32 output(input.n(), weights.output_channels, output_h, output_w);
  const int output_channels_per_group = weights.output_channels / config.groups;

  for (int n = 0; n < input.n(); ++n) {
    for (int oc = 0; oc < weights.output_channels; ++oc) {
      const int group = oc / output_channels_per_group;
      const int input_channel_base = group * weights.input_channels_per_group;
      for (int oy = 0; oy < output_h; ++oy) {
        for (int ox = 0; ox < output_w; ++ox) {
          std::int64_t accumulator = 0;
          for (int ky = 0; ky < weights.kernel_h; ++ky) {
            const int iy = oy * config.geometry.stride_h - config.geometry.pad_h +
                           ky * config.geometry.dilation_h;
            for (int kx = 0; kx < weights.kernel_w; ++kx) {
              const int ix = ox * config.geometry.stride_w - config.geometry.pad_w +
                             kx * config.geometry.dilation_w;
              if (iy < 0 || iy >= input.h() || ix < 0 || ix >= input.w()) {
                continue;
              }
              for (int ic = 0; ic < weights.input_channels_per_group; ++ic) {
                accumulator +=
                    static_cast<std::int32_t>(
                        input.at(n, input_channel_base + ic, iy, ix)) *
                    static_cast<std::int32_t>(weights.at(oc, ic, ky, kx));
              }
            }
          }
          output.at(n, oc, oy, ox) = checked_accumulator(accumulator);
        }
      }
    }
  }
  return output;
}

TensorI8 conv2d_requantize(const TensorI32& accumulators,
                           const std::vector<RequantParams>& params) {
  if (params.size() != 1 &&
      params.size() != static_cast<std::size_t>(accumulators.c())) {
    throw std::invalid_argument("Conv2D requant params must be per-layer or per-channel");
  }
  TensorI8 output(accumulators.n(), accumulators.c(), accumulators.h(),
                  accumulators.w());
  for (int n = 0; n < output.n(); ++n) {
    for (int c = 0; c < output.c(); ++c) {
      const RequantParams& q = channel_params(params, c);
      for (int y = 0; y < output.h(); ++y) {
        for (int x = 0; x < output.w(); ++x) {
          output.at(n, c, y, x) = requantize(accumulators.at(n, c, y, x), q);
        }
      }
    }
  }
  return output;
}

TensorI8 conv2d(const TensorI8& input, const ConvWeightsI8& weights,
                const Conv2DConfig& config,
                const std::vector<RequantParams>& params) {
  return conv2d_requantize(conv2d_accumulate(input, weights, config), params);
}

}  // namespace alexnet::golden

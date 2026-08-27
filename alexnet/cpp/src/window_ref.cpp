#include "alexnet_golden/window_ref.hpp"

#include <stdexcept>

namespace alexnet::golden {

int conv_output_dim(int input, int kernel, int stride, int padding,
                    int dilation) {
  if (input <= 0 || kernel <= 0 || stride <= 0 || padding < 0 || dilation <= 0) {
    throw std::invalid_argument("invalid convolution dimension parameter");
  }
  const int effective_kernel = dilation * (kernel - 1) + 1;
  const int numerator = input + 2 * padding - effective_kernel;
  if (numerator < 0) {
    throw std::invalid_argument("effective kernel is larger than padded input");
  }
  return numerator / stride + 1;
}

int conv_k_depth(int input_channels_per_group, const ConvGeometry& geometry) {
  if (input_channels_per_group <= 0 || geometry.kernel_h <= 0 ||
      geometry.kernel_w <= 0) {
    throw std::invalid_argument("invalid convolution K depth parameter");
  }
  return input_channels_per_group * geometry.kernel_h * geometry.kernel_w;
}

std::vector<WindowToken> make_window_tokens(
    const TensorI8& input, int batch, int input_channel_base,
    int input_channels_per_group, const ConvGeometry& geometry,
    int output_position_base, int lane_count) {
  if (batch < 0 || batch >= input.n()) {
    throw std::out_of_range("window batch is out of range");
  }
  if (input_channel_base < 0 || input_channels_per_group <= 0 ||
      input_channel_base + input_channels_per_group > input.c()) {
    throw std::out_of_range("window input channel group is out of range");
  }
  if (output_position_base < 0 || lane_count <= 0) {
    throw std::invalid_argument("invalid output tile location");
  }

  const int output_h = conv_output_dim(input.h(), geometry.kernel_h,
                                       geometry.stride_h, geometry.pad_h,
                                       geometry.dilation_h);
  const int output_w = conv_output_dim(input.w(), geometry.kernel_w,
                                       geometry.stride_w, geometry.pad_w,
                                       geometry.dilation_w);
  const int output_positions = output_h * output_w;
  const int depth = conv_k_depth(input_channels_per_group, geometry);

  std::vector<WindowToken> tokens;
  tokens.reserve(static_cast<std::size_t>(depth));

  int k = 0;
  for (int ky = 0; ky < geometry.kernel_h; ++ky) {
    for (int kx = 0; kx < geometry.kernel_w; ++kx) {
      for (int ic = 0; ic < input_channels_per_group; ++ic, ++k) {
        WindowToken token;
        token.k = k;
        token.kernel_y = ky;
        token.kernel_x = kx;
        token.input_channel = ic;
        token.activations.resize(static_cast<std::size_t>(lane_count), 0);
        token.lane_valid.resize(static_cast<std::size_t>(lane_count), 0);
        token.reduce_last = (k == depth - 1);

        for (int lane = 0; lane < lane_count; ++lane) {
          const int output_position = output_position_base + lane;
          if (output_position >= output_positions) {
            continue;
          }

          const int output_y = output_position / output_w;
          const int output_x = output_position % output_w;
          const int input_y = output_y * geometry.stride_h - geometry.pad_h +
                              ky * geometry.dilation_h;
          const int input_x = output_x * geometry.stride_w - geometry.pad_w +
                              kx * geometry.dilation_w;

          token.lane_valid[static_cast<std::size_t>(lane)] = 1;
          if (input_y >= 0 && input_y < input.h() && input_x >= 0 &&
              input_x < input.w()) {
            token.activations[static_cast<std::size_t>(lane)] =
                input.at(batch, input_channel_base + ic, input_y, input_x);
          }
        }
        tokens.push_back(std::move(token));
      }
    }
  }
  return tokens;
}

}  // namespace alexnet::golden

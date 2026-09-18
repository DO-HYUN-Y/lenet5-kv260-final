#include <array>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#include "alexnet_golden/alexnet_ref.hpp"

namespace ag = alexnet::golden;
namespace fs = std::filesystem;

namespace {

std::vector<std::int8_t> read_i8(const fs::path& path,
                                 std::size_t expected_bytes) {
  std::ifstream stream(path, std::ios::binary | std::ios::ate);
  if (!stream) {
    throw std::runtime_error("cannot open " + path.string());
  }
  const auto length = stream.tellg();
  if (length < 0 || static_cast<std::size_t>(length) != expected_bytes) {
    throw std::runtime_error("unexpected byte count for " + path.string());
  }
  stream.seekg(0);
  std::vector<std::int8_t> result(expected_bytes);
  stream.read(reinterpret_cast<char*>(result.data()),
              static_cast<std::streamsize>(result.size()));
  if (!stream) {
    throw std::runtime_error("short read from " + path.string());
  }
  return result;
}

std::vector<std::int8_t> read_i8_prefix(const fs::path& path,
                                        std::size_t prefix_bytes) {
  std::ifstream stream(path, std::ios::binary);
  if (!stream) {
    throw std::runtime_error("cannot open " + path.string());
  }
  std::vector<std::int8_t> result(prefix_bytes);
  stream.read(reinterpret_cast<char*>(result.data()),
              static_cast<std::streamsize>(result.size()));
  if (!stream) {
    throw std::runtime_error("short prefix read from " + path.string());
  }
  return result;
}

std::uint32_t little_u32(const std::uint8_t* bytes) {
  return static_cast<std::uint32_t>(bytes[0]) |
         (static_cast<std::uint32_t>(bytes[1]) << 8) |
         (static_cast<std::uint32_t>(bytes[2]) << 16) |
         (static_cast<std::uint32_t>(bytes[3]) << 24);
}

std::vector<ag::RequantParams> read_parameters(const fs::path& path,
                                                int output_count) {
  std::ifstream stream(path, std::ios::binary);
  if (!stream) {
    throw std::runtime_error("cannot open " + path.string());
  }
  std::vector<ag::RequantParams> result;
  result.reserve(static_cast<std::size_t>(output_count));
  for (int output = 0; output < output_count; ++output) {
    std::array<std::uint8_t, 16> record{};
    stream.read(reinterpret_cast<char*>(record.data()), record.size());
    if (!stream) {
      throw std::runtime_error("short parameter read from " + path.string());
    }
    ag::RequantParams params;
    const std::uint32_t bias_bits = little_u32(record.data());
    const std::uint32_t multiplier_bits = little_u32(record.data() + 4);
    std::memcpy(&params.bias, &bias_bits, sizeof(params.bias));
    std::memcpy(&params.multiplier, &multiplier_bits,
                sizeof(params.multiplier));
    params.right_shift = record[8];
    params.relu = record[9] != 0;
    result.push_back(params);
  }
  if (stream.peek() != std::ifstream::traits_type::eof()) {
    throw std::runtime_error("extra parameter bytes in " + path.string());
  }
  return result;
}

ag::ConvLayerRef load_conv(const fs::path& board_dir,
                           const std::string& name, int output_channels,
                           int input_channels, int kernel, int stride,
                           int padding) {
  ag::ConvLayerRef layer;
  layer.weights.output_channels = output_channels;
  layer.weights.input_channels_per_group = input_channels;
  layer.weights.kernel_h = kernel;
  layer.weights.kernel_w = kernel;
  const std::size_t weight_bytes =
      static_cast<std::size_t>(output_channels) * input_channels * kernel *
      kernel;
  layer.weights.values = read_i8(board_dir / "logical_weights_oihw_nk" /
                                     (name + ".bin"),
                                 weight_bytes);
  layer.config.geometry = {kernel, kernel, stride, stride, padding, padding,
                           1, 1};
  layer.config.groups = 1;
  layer.quant = read_parameters(
      board_dir / "layer_parameters" / (name + ".bin"), output_channels);
  return layer;
}

ag::LinearLayerRef load_linear(const fs::path& board_dir,
                               const std::string& name, int output_features,
                               int input_features) {
  ag::LinearLayerRef layer;
  layer.weights = ag::MatrixI8(
      output_features, input_features,
      read_i8(board_dir / "logical_weights_oihw_nk" / (name + ".bin"),
              static_cast<std::size_t>(output_features) * input_features));
  layer.quant = read_parameters(
      board_dir / "layer_parameters" / (name + ".bin"), output_features);
  return layer;
}

ag::AlexNetInt8Parameters load_parameters(const fs::path& board_dir) {
  ag::AlexNetInt8Parameters parameters;
  parameters.conv1 = load_conv(board_dir, "conv1", 64, 3, 11, 4, 2);
  parameters.conv2 = load_conv(board_dir, "conv2", 192, 64, 5, 1, 2);
  parameters.conv3 = load_conv(board_dir, "conv3", 384, 192, 3, 1, 1);
  parameters.conv4 = load_conv(board_dir, "conv4", 256, 384, 3, 1, 1);
  parameters.conv5 = load_conv(board_dir, "conv5", 256, 256, 3, 1, 1);
  parameters.fc6 = load_linear(board_dir, "fc6", 4096, 9216);
  parameters.fc7 = load_linear(board_dir, "fc7", 4096, 4096);
  parameters.fc8 = load_linear(board_dir, "fc8", 1000, 4096);
  return parameters;
}

ag::TensorI8 make_input() {
  ag::TensorI8 input(1, 3, 224, 224);
  for (int channel = 0; channel < input.c(); ++channel) {
    for (int y = 0; y < input.h(); ++y) {
      for (int x = 0; x < input.w(); ++x) {
        const int value =
            (channel * 53 + y * 7 + x * 11 + (y * x) % 29 + 13) % 255 - 127;
        input.at(0, channel, y, x) = static_cast<std::int8_t>(value);
      }
    }
  }
  return input;
}

std::vector<std::int8_t> to_n8_tile_major(const ag::TensorI8& tensor) {
  if (tensor.n() != 1) {
    throw std::invalid_argument("board golden supports batch one only");
  }
  const int channel_tiles = (tensor.c() + 7) / 8;
  std::vector<std::int8_t> result;
  result.reserve(static_cast<std::size_t>(channel_tiles) * tensor.h() *
                 tensor.w() * 8);
  for (int tile = 0; tile < channel_tiles; ++tile) {
    for (int y = 0; y < tensor.h(); ++y) {
      for (int x = 0; x < tensor.w(); ++x) {
        for (int lane = 0; lane < 8; ++lane) {
          const int channel = tile * 8 + lane;
          result.push_back(channel < tensor.c()
                               ? tensor.at(0, channel, y, x)
                               : std::int8_t{0});
        }
      }
    }
  }
  return result;
}

std::vector<std::int8_t> to_n8_tile_major(const ag::MatrixI8& matrix) {
  if (matrix.rows() != 1) {
    throw std::invalid_argument("board golden supports batch one only");
  }
  const int feature_tiles = (matrix.cols() + 7) / 8;
  std::vector<std::int8_t> result;
  result.reserve(static_cast<std::size_t>(feature_tiles) * 8);
  for (int tile = 0; tile < feature_tiles; ++tile) {
    for (int lane = 0; lane < 8; ++lane) {
      const int feature = tile * 8 + lane;
      result.push_back(feature < matrix.cols() ? matrix.at(0, feature)
                                               : std::int8_t{0});
    }
  }
  return result;
}

void write_bytes(const fs::path& path,
                 const std::vector<std::int8_t>& bytes) {
  std::ofstream stream(path, std::ios::binary);
  if (!stream) {
    throw std::runtime_error("cannot create " + path.string());
  }
  stream.write(reinterpret_cast<const char*>(bytes.data()),
               static_cast<std::streamsize>(bytes.size()));
  if (!stream) {
    throw std::runtime_error("short write to " + path.string());
  }
  std::cout << path.filename().string() << " " << bytes.size() << " bytes\n";
}

void write_hex_word(std::ofstream& stream,
                    const std::vector<std::int8_t>& bytes) {
  for (auto iterator = bytes.rbegin(); iterator != bytes.rend(); ++iterator) {
    stream << std::hex << std::setw(2) << std::setfill('0')
           << static_cast<unsigned>(static_cast<std::uint8_t>(*iterator));
  }
  stream << '\n';
}

void write_axis128_mem(const fs::path& path,
                       const std::vector<std::int8_t>& bytes) {
  if (bytes.size() % 16 != 0) {
    throw std::invalid_argument("AXIS128 vector must contain complete beats");
  }
  std::ofstream stream(path);
  if (!stream) {
    throw std::runtime_error("cannot create " + path.string());
  }
  for (std::size_t offset = 0; offset < bytes.size(); offset += 16) {
    const std::vector<std::int8_t> word(bytes.begin() + offset,
                                        bytes.begin() + offset + 16);
    write_hex_word(stream, word);
  }
}

void write_axis64_mem(const fs::path& path,
                      const std::vector<std::int8_t>& bytes) {
  if (bytes.size() % 8 != 0) {
    throw std::invalid_argument("AXIS64 vector must contain complete rows");
  }
  std::ofstream stream(path);
  if (!stream) {
    throw std::runtime_error("cannot create " + path.string());
  }
  for (std::size_t offset = 0; offset < bytes.size(); offset += 8) {
    const std::vector<std::int8_t> word(bytes.begin() + offset,
                                        bytes.begin() + offset + 8);
    write_hex_word(stream, word);
  }
}

void write_parameter_mem(const fs::path& path,
                         const std::vector<ag::RequantParams>& params,
                         int output_count) {
  std::ofstream stream(path);
  if (!stream) {
    throw std::runtime_error("cannot create " + path.string());
  }
  for (int output = 0; output < output_count; ++output) {
    const auto& parameter = params.at(static_cast<std::size_t>(output));
    std::uint32_t bias_bits = 0;
    std::memcpy(&bias_bits, &parameter.bias, sizeof(bias_bits));
    const std::uint64_t packed = static_cast<std::uint64_t>(bias_bits) |
        (static_cast<std::uint64_t>(
             static_cast<std::uint32_t>(parameter.multiplier) & 0x3ffffU)
         << 32) |
        (static_cast<std::uint64_t>(parameter.right_shift & 0x3fU) << 50) |
        (static_cast<std::uint64_t>(parameter.relu) << 56);
    stream << std::hex << std::setw(16) << std::setfill('0') << packed
           << '\n';
  }
}

void write_expected_mem(const fs::path& path, const ag::TensorI8& output,
                        int m_count, int n_count) {
  std::ofstream stream(path);
  if (!stream) {
    throw std::runtime_error("cannot create " + path.string());
  }
  for (int m = 0; m < m_count; ++m) {
    const int y = m / output.w();
    const int x = m % output.w();
    for (int n = 0; n < n_count; ++n) {
      stream << std::hex << std::setw(2) << std::setfill('0')
             << static_cast<unsigned>(static_cast<std::uint8_t>(
                    output.at(0, n, y, x)))
             << '\n';
    }
  }
}

void write_expected_mem(const fs::path& path, const ag::MatrixI8& output,
                        int n_count) {
  std::ofstream stream(path);
  if (!stream) {
    throw std::runtime_error("cannot create " + path.string());
  }
  for (int n = 0; n < n_count; ++n) {
    stream << std::hex << std::setw(2) << std::setfill('0')
           << static_cast<unsigned>(
                  static_cast<std::uint8_t>(output.at(0, n)))
           << '\n';
  }
}

void write_conv_rtl_tile(const fs::path& output_dir, int layer_id,
                         const ag::TensorI8& input,
                         const ag::ConvLayerRef& layer,
                         const ag::TensorI8& output, int m_count,
                         int n_count) {
  const fs::path tile_dir =
      output_dir / "rtl_tiles" / ("layer" + std::to_string(layer_id));
  fs::create_directories(tile_dir);
  std::ofstream patches(tile_dir / "patch.mem");
  std::ofstream weights(tile_dir / "weight.mem");
  if (!patches || !weights) {
    throw std::runtime_error("cannot create Conv RTL tile vectors");
  }
  const auto& geometry = layer.config.geometry;
  const int k_count = geometry.kernel_h * geometry.kernel_w * input.c();
  for (int k = 0; k < k_count; ++k) {
    const int input_channel = k % input.c();
    const int kernel_index = k / input.c();
    const int kernel_x = kernel_index % geometry.kernel_w;
    const int kernel_y = kernel_index / geometry.kernel_w;
    std::vector<std::int8_t> patch_word(16, 0);
    for (int m = 0; m < m_count; ++m) {
      const int output_y = m / output.w();
      const int output_x = m % output.w();
      const int input_y = output_y * geometry.stride_h - geometry.pad_h +
                          kernel_y * geometry.dilation_h;
      const int input_x = output_x * geometry.stride_w - geometry.pad_w +
                          kernel_x * geometry.dilation_w;
      if (input_y >= 0 && input_y < input.h() && input_x >= 0 &&
          input_x < input.w()) {
        patch_word[static_cast<std::size_t>(m)] =
            input.at(0, input_channel, input_y, input_x);
      }
    }
    write_hex_word(patches, patch_word);

    std::vector<std::int8_t> weight_word(128, 0);
    for (int n = 0; n < n_count; ++n) {
      weight_word[static_cast<std::size_t>(n)] = layer.weights.at(
          n, input_channel, kernel_y, kernel_x);
    }
    write_hex_word(weights, weight_word);
  }
  write_parameter_mem(tile_dir / "parameter.mem", layer.quant, n_count);
  write_expected_mem(tile_dir / "expected.mem", output, m_count, n_count);
}

void write_linear_rtl_tile(const fs::path& output_dir, int layer_id,
                           const ag::MatrixI8& input,
                           const ag::LinearLayerRef& layer,
                           const ag::MatrixI8& output) {
  constexpr int kNCount = 16;
  const fs::path tile_dir =
      output_dir / "rtl_tiles" / ("layer" + std::to_string(layer_id));
  fs::create_directories(tile_dir);
  std::ofstream patches(tile_dir / "patch.mem");
  std::ofstream weights(tile_dir / "weight.mem");
  if (!patches || !weights) {
    throw std::runtime_error("cannot create FC RTL tile vectors");
  }
  for (int k = 0; k < input.cols(); ++k) {
    std::vector<std::int8_t> patch_word(16, 0);
    patch_word[0] = input.at(0, k);
    write_hex_word(patches, patch_word);
    std::vector<std::int8_t> weight_word(128, 0);
    for (int n = 0; n < kNCount; ++n) {
      weight_word[static_cast<std::size_t>(n)] = layer.weights.at(n, k);
    }
    write_hex_word(weights, weight_word);
  }
  write_parameter_mem(tile_dir / "parameter.mem", layer.quant, kNCount);
  write_expected_mem(tile_dir / "expected.mem", output, kNCount);
}

}  // namespace

int main(int argc, char** argv) {
  try {
    if (argc != 3) {
      std::cerr << "usage: " << argv[0]
                << " BOARD_MODEL_DIR OUTPUT_VECTOR_DIR\n";
      return 2;
    }
    const fs::path board_dir = fs::absolute(argv[1]);
    const fs::path output_dir = fs::absolute(argv[2]);
    fs::create_directories(output_dir);

    std::cout << "loading board model from " << board_dir.string() << '\n';
    const auto parameters = load_parameters(board_dir);
    const auto input = make_input();
    std::cout << "running Conv1 through FC8 C++ golden\n";
    const auto outputs = ag::run_alexnet_int8(input, parameters);

    write_bytes(output_dir / "input_n8.bin", to_n8_tile_major(input));
    write_bytes(output_dir / "conv1.bin", to_n8_tile_major(outputs.conv1));
    write_bytes(output_dir / "pool1.bin", to_n8_tile_major(outputs.pool1));
    write_bytes(output_dir / "conv2.bin", to_n8_tile_major(outputs.conv2));
    write_bytes(output_dir / "pool2.bin", to_n8_tile_major(outputs.pool2));
    write_bytes(output_dir / "conv3.bin", to_n8_tile_major(outputs.conv3));
    write_bytes(output_dir / "conv4.bin", to_n8_tile_major(outputs.conv4));
    write_bytes(output_dir / "conv5.bin", to_n8_tile_major(outputs.conv5));
    write_bytes(output_dir / "pool5.bin", to_n8_tile_major(outputs.pool5));
    write_bytes(output_dir / "fc6.bin", to_n8_tile_major(outputs.fc6));
    write_bytes(output_dir / "fc7.bin", to_n8_tile_major(outputs.fc7));
    write_bytes(output_dir / "fc8.bin", to_n8_tile_major(outputs.logits));

    write_conv_rtl_tile(output_dir, 1, input, parameters.conv1, outputs.conv1,
                        16, 64);
    write_conv_rtl_tile(output_dir, 2, outputs.pool1, parameters.conv2,
                        outputs.conv2, 16, 64);
    write_conv_rtl_tile(output_dir, 3, outputs.pool2, parameters.conv3,
                        outputs.conv3, 8, 112);
    write_conv_rtl_tile(output_dir, 4, outputs.conv3, parameters.conv4,
                        outputs.conv4, 8, 112);
    write_conv_rtl_tile(output_dir, 5, outputs.conv4, parameters.conv5,
                        outputs.conv5, 8, 112);
    const auto fc6_input = ag::flatten_nchw(outputs.pool5);
    write_linear_rtl_tile(output_dir, 6, fc6_input, parameters.fc6,
                          outputs.fc6);
    write_linear_rtl_tile(output_dir, 7, outputs.fc6, parameters.fc7,
                          outputs.fc7);
    write_linear_rtl_tile(output_dir, 8, outputs.fc7, parameters.fc8,
                          outputs.logits);

    // Small, deterministic vectors for the first integrated-top checkpoint.
    // These exercise the normal Conv1 raster DMA, the format-v2 physical
    // weight stream, parameter records and the first scatter write without
    // loading the complete 61 MB weight image into an RTL testbench.
    const fs::path smoke_dir = output_dir / "top_conv1_smoke";
    fs::create_directories(smoke_dir);
    const auto input_axis = to_n8_tile_major(input);
    const auto first_weight_request =
        read_i8_prefix(board_dir / "weights_board.bin", 4 * 363 * 16);
    const auto first_parameters =
        read_i8_prefix(board_dir / "parameters_board.bin", 8 * 16);
    auto first_conv1_result = to_n8_tile_major(outputs.conv1);
    first_conv1_result.resize(8 * 8);
    write_axis128_mem(smoke_dir / "input_axis128.mem", input_axis);
    write_axis128_mem(smoke_dir / "weight_axis128.mem",
                      first_weight_request);
    write_axis128_mem(smoke_dir / "parameter_axis128.mem",
                      first_parameters);
    write_axis128_mem(smoke_dir / "expected_result_axis128.mem",
                      first_conv1_result);
    write_axis64_mem(smoke_dir / "expected_result_axis64.mem",
                     first_conv1_result);

    // Full Conv1 integrated-top gate. The same physical weights are replayed
    // across 190 spatial descriptors; all 64 parameter records and the full
    // N8-tile-major result image are needed for the 3,032 scatter writes.
    const fs::path conv1_dir = output_dir / "top_conv1_full";
    fs::create_directories(conv1_dir);
    const auto conv1_parameters =
        read_i8_prefix(board_dir / "parameters_board.bin", 64 * 16);
    write_axis128_mem(conv1_dir / "input_axis128.mem", input_axis);
    write_axis128_mem(conv1_dir / "weight_axis128.mem",
                      first_weight_request);
    write_axis128_mem(conv1_dir / "parameter_axis128.mem",
                      conv1_parameters);
    write_axis64_mem(conv1_dir / "expected_result_axis64.mem",
                     to_n8_tile_major(outputs.conv1));

    // Compact 64-bit rows for one continuous integrated-top run. Keeping the
    // full board weight/parameter images binary avoids creating a multi-million
    // line text file; the DMA BFM reads those binaries at transfer time.
    const fs::path full_graph_dir = output_dir / "full_graph_axis64";
    fs::create_directories(full_graph_dir);
    write_axis64_mem(full_graph_dir / "conv1.mem",
                     to_n8_tile_major(outputs.conv1));
    write_axis64_mem(full_graph_dir / "pool1.mem",
                     to_n8_tile_major(outputs.pool1));
    write_axis64_mem(full_graph_dir / "conv2.mem",
                     to_n8_tile_major(outputs.conv2));
    write_axis64_mem(full_graph_dir / "pool2.mem",
                     to_n8_tile_major(outputs.pool2));
    write_axis64_mem(full_graph_dir / "conv3.mem",
                     to_n8_tile_major(outputs.conv3));
    write_axis64_mem(full_graph_dir / "conv4.mem",
                     to_n8_tile_major(outputs.conv4));
    write_axis64_mem(full_graph_dir / "conv5.mem",
                     to_n8_tile_major(outputs.conv5));
    write_axis64_mem(full_graph_dir / "pool5.mem",
                     to_n8_tile_major(outputs.pool5));
    write_axis64_mem(full_graph_dir / "fc6.mem",
                     to_n8_tile_major(outputs.fc6));
    write_axis64_mem(full_graph_dir / "fc7.mem",
                     to_n8_tile_major(outputs.fc7));
    write_axis64_mem(full_graph_dir / "fc8.mem",
                     to_n8_tile_major(outputs.logits));

    std::cout << "ALEXNET_BOARD_FULL_GRAPH_GOLDEN_PASS\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "ALEXNET_BOARD_FULL_GRAPH_GOLDEN_FAIL: " << error.what()
              << '\n';
    return 1;
  }
}

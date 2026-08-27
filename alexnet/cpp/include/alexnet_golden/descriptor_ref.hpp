#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

#include "alexnet_golden/window_ref.hpp"

namespace alexnet::golden {

enum class OperatorKind { kConv2D, kLinear };
enum class DataflowMode { kWeightMajor, kActivationSlab, kFcBatch };

struct RuntimeDescriptor {
  int version = 1;
  OperatorKind op = OperatorKind::kConv2D;
  DataflowMode dataflow = DataflowMode::kWeightMajor;
  int batch = 1;
  int input_channels = 1;
  int input_h = 1;
  int input_w = 1;
  int output_channels = 1;
  int groups = 1;
  ConvGeometry geometry{};
  int m_tile = 32;
  int n_tile = 64;
};

struct DerivedDescriptor {
  int output_h = 1;
  int output_w = 1;
  int output_positions = 1;
  int input_channels_per_group = 1;
  int output_channels_per_group = 1;
  int k_depth = 1;
  int n_tiles_per_group = 1;
};

struct TileWorkItem {
  int group = 0;
  int output_channel_base = 0;
  int output_channel_count = 0;
  int batch_base = 0;
  int batch_count = 0;
  int spatial_base = 0;
  int spatial_count = 0;
  int k_depth = 0;
  bool first_for_weight_tile = false;
  bool last_for_weight_tile = false;
};

struct DdrBaseAddresses {
  std::uint64_t input = 0;
  std::uint64_t weight = 0;
  std::uint64_t parameter = 0;
  std::uint64_t output = 0;
};

struct TileDdrAddresses {
  std::uint64_t weight = 0;
  std::uint64_t parameter = 0;
  std::uint64_t first_output = 0;
};

DerivedDescriptor derive_descriptor(const RuntimeDescriptor& descriptor);
std::vector<TileWorkItem> make_weight_major_schedule(
    const RuntimeDescriptor& descriptor);

std::size_t weight_tile_bytes(const RuntimeDescriptor& descriptor,
                              const TileWorkItem& item);

std::size_t weight_tile_byte_offset(const RuntimeDescriptor& descriptor,
                                    const TileWorkItem& item);
std::uint64_t nchw_i8_address(std::uint64_t base, int n, int c, int h, int w,
                             int channels, int height, int width);
TileDdrAddresses resolve_tile_ddr_addresses(
    const RuntimeDescriptor& descriptor, const TileWorkItem& item,
    const DdrBaseAddresses& bases);

}  // namespace alexnet::golden

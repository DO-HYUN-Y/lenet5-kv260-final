#include "alexnet_golden/descriptor_ref.hpp"

#include <algorithm>
#include <limits>
#include <stdexcept>

namespace alexnet::golden {
namespace {

int ceil_div(int numerator, int denominator) {
  return (numerator + denominator - 1) / denominator;
}

std::uint64_t checked_address_add(std::uint64_t base, std::size_t offset) {
  if (offset > std::numeric_limits<std::uint64_t>::max() - base) {
    throw std::overflow_error("DDR address overflow");
  }
  return base + static_cast<std::uint64_t>(offset);
}

void validate_work_item(const RuntimeDescriptor& descriptor,
                        const DerivedDescriptor& derived,
                        const TileWorkItem& item) {
  if (item.group < 0 || item.group >= descriptor.groups ||
      item.k_depth != derived.k_depth || item.output_channel_count <= 0 ||
      item.output_channel_count > descriptor.n_tile || item.batch_base < 0 ||
      item.batch_count <= 0 ||
      item.batch_base + item.batch_count > descriptor.batch) {
    throw std::invalid_argument("work item does not match descriptor");
  }
  const int group_output_begin = item.group * derived.output_channels_per_group;
  const int group_output_end = group_output_begin + derived.output_channels_per_group;
  if (item.output_channel_base < group_output_begin ||
      item.output_channel_base + item.output_channel_count > group_output_end ||
      (item.output_channel_base - group_output_begin) % descriptor.n_tile != 0) {
    throw std::invalid_argument("work item output tile does not match group");
  }
  if (descriptor.op == OperatorKind::kConv2D) {
    if (item.batch_count != 1 || item.spatial_base < 0 ||
        item.spatial_count <= 0 ||
        item.spatial_base + item.spatial_count > derived.output_positions) {
      throw std::invalid_argument("convolution work item range is invalid");
    }
  } else if (item.spatial_base != 0 || item.spatial_count != 1) {
    throw std::invalid_argument("linear work item spatial range is invalid");
  }
}

}  // namespace

DerivedDescriptor derive_descriptor(const RuntimeDescriptor& descriptor) {
  if (descriptor.version != 1 || descriptor.batch <= 0 ||
      descriptor.input_channels <= 0 || descriptor.output_channels <= 0 ||
      descriptor.groups <= 0 || descriptor.m_tile <= 0 || descriptor.n_tile <= 0 ||
      descriptor.input_channels % descriptor.groups != 0 ||
      descriptor.output_channels % descriptor.groups != 0) {
    throw std::invalid_argument("invalid runtime descriptor");
  }

  DerivedDescriptor derived;
  derived.input_channels_per_group = descriptor.input_channels / descriptor.groups;
  derived.output_channels_per_group = descriptor.output_channels / descriptor.groups;

  if (descriptor.op == OperatorKind::kConv2D) {
    derived.output_h = conv_output_dim(
        descriptor.input_h, descriptor.geometry.kernel_h,
        descriptor.geometry.stride_h, descriptor.geometry.pad_h,
        descriptor.geometry.dilation_h);
    derived.output_w = conv_output_dim(
        descriptor.input_w, descriptor.geometry.kernel_w,
        descriptor.geometry.stride_w, descriptor.geometry.pad_w,
        descriptor.geometry.dilation_w);
    derived.output_positions = derived.output_h * derived.output_w;
    derived.k_depth =
        conv_k_depth(derived.input_channels_per_group, descriptor.geometry);
  } else {
    if (descriptor.groups != 1 || descriptor.input_h != 1 ||
        descriptor.input_w != 1) {
      throw std::invalid_argument("linear descriptor requires groups=1 and H=W=1");
    }
    derived.output_h = 1;
    derived.output_w = 1;
    derived.output_positions = 1;
    derived.k_depth = descriptor.input_channels;
  }
  derived.n_tiles_per_group =
      ceil_div(derived.output_channels_per_group, descriptor.n_tile);
  return derived;
}

std::vector<TileWorkItem> make_weight_major_schedule(
    const RuntimeDescriptor& descriptor) {
  const DerivedDescriptor derived = derive_descriptor(descriptor);
  std::vector<TileWorkItem> schedule;

  for (int group = 0; group < descriptor.groups; ++group) {
    const int group_output_base = group * derived.output_channels_per_group;
    for (int n_tile_index = 0; n_tile_index < derived.n_tiles_per_group;
         ++n_tile_index) {
      const int oc_base = group_output_base + n_tile_index * descriptor.n_tile;
      const int oc_count = std::min(
          descriptor.n_tile,
          group_output_base + derived.output_channels_per_group - oc_base);
      const std::size_t tile_begin = schedule.size();

      if (descriptor.op == OperatorKind::kConv2D) {
        for (int batch = 0; batch < descriptor.batch; ++batch) {
          for (int spatial = 0; spatial < derived.output_positions;
               spatial += descriptor.m_tile) {
            schedule.push_back(TileWorkItem{
                group,
                oc_base,
                oc_count,
                batch,
                1,
                spatial,
                std::min(descriptor.m_tile, derived.output_positions - spatial),
                derived.k_depth,
                false,
                false});
          }
        }
      } else {
        for (int batch = 0; batch < descriptor.batch; batch += descriptor.m_tile) {
          schedule.push_back(TileWorkItem{
              0,
              oc_base,
              oc_count,
              batch,
              std::min(descriptor.m_tile, descriptor.batch - batch),
              0,
              1,
              derived.k_depth,
              false,
              false});
        }
      }

      if (schedule.size() == tile_begin) {
        throw std::logic_error("descriptor generated an empty weight tile schedule");
      }
      schedule[tile_begin].first_for_weight_tile = true;
      schedule.back().last_for_weight_tile = true;
    }
  }
  return schedule;
}

std::size_t weight_tile_bytes(const RuntimeDescriptor& descriptor,
                              const TileWorkItem& item) {
  const DerivedDescriptor derived = derive_descriptor(descriptor);
  validate_work_item(descriptor, derived, item);
  return static_cast<std::size_t>(derived.k_depth) * descriptor.n_tile;
}

std::size_t weight_tile_byte_offset(const RuntimeDescriptor& descriptor,
                                    const TileWorkItem& item) {
  const DerivedDescriptor derived = derive_descriptor(descriptor);
  validate_work_item(descriptor, derived, item);
  const int group_output_begin = item.group * derived.output_channels_per_group;
  const int tile_in_group =
      (item.output_channel_base - group_output_begin) / descriptor.n_tile;
  const std::size_t global_tile =
      static_cast<std::size_t>(item.group) * derived.n_tiles_per_group +
      static_cast<std::size_t>(tile_in_group);
  return global_tile * static_cast<std::size_t>(derived.k_depth) *
         descriptor.n_tile;
}

std::uint64_t nchw_i8_address(std::uint64_t base, int n, int c, int h, int w,
                             int channels, int height, int width) {
  if (n < 0 || c < 0 || c >= channels || h < 0 || h >= height || w < 0 ||
      w >= width || channels <= 0 || height <= 0 || width <= 0) {
    throw std::out_of_range("NCHW DDR coordinate is out of range");
  }
  const std::size_t offset =
      ((static_cast<std::size_t>(n) * channels + c) * height + h) * width + w;
  return checked_address_add(base, offset);
}

TileDdrAddresses resolve_tile_ddr_addresses(
    const RuntimeDescriptor& descriptor, const TileWorkItem& item,
    const DdrBaseAddresses& bases) {
  const DerivedDescriptor derived = derive_descriptor(descriptor);
  validate_work_item(descriptor, derived, item);
  const std::size_t weight_offset = weight_tile_byte_offset(descriptor, item);
  const std::size_t parameter_offset =
      static_cast<std::size_t>(item.output_channel_base) * 16;
  const int spatial_y = item.spatial_base / derived.output_w;
  const int spatial_x = item.spatial_base % derived.output_w;
  return TileDdrAddresses{
      checked_address_add(bases.weight, weight_offset),
      checked_address_add(bases.parameter, parameter_offset),
      nchw_i8_address(bases.output, item.batch_base,
                      item.output_channel_base, spatial_y, spatial_x,
                      descriptor.output_channels, derived.output_h,
                      derived.output_w)};
}

}  // namespace alexnet::golden

#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <optional>

namespace alexnet::golden {

enum class OutputDestination : std::uint8_t {
  kActivationBuffer = 0,
  kPool3x3 = 1,
  kFinalOutput = 2,
};

struct OutputRouterIngress {
  int m = 0;
  int tile_tag = 0;
  std::uint8_t lane_mask = 0;
  std::array<std::int8_t, 8> values{};
};

struct OutputRouterPacket {
  OutputDestination destination = OutputDestination::kActivationBuffer;
  int slice = 0;
  int m = 0;
  int n_base = 0;
  int tile_tag = 0;
  std::uint8_t lane_mask = 0;
  std::array<std::int8_t, 8> values{};
};

struct OutputRouterCycle {
  bool ingress_ready = false;
  std::optional<OutputRouterPacket> egress;
};

// One of eight independent N8 output-router slices. A packet is 8 INT8 values
// at one M coordinate. The configured destination and N64 tile base remain
// constant until the FIFO drains, matching a layer/tile descriptor in RTL.
class N8OutputRouterRef {
 public:
  explicit N8OutputRouterRef(int slice, std::size_t fifo_depth = 64);

  void reset();
  void configure(OutputDestination destination, int n64_tile_base);
  OutputRouterCycle tick(bool ingress_valid,
                         const OutputRouterIngress& ingress,
                         bool egress_ready);

  bool configured() const { return configured_; }
  bool idle() const { return fifo_.empty(); }
  std::size_t queued_packets() const { return fifo_.size(); }
  std::size_t fifo_depth() const { return fifo_depth_; }

 private:
  OutputRouterPacket make_packet(const OutputRouterIngress& ingress) const;

  int slice_ = 0;
  std::size_t fifo_depth_ = 0;
  bool configured_ = false;
  OutputDestination destination_ = OutputDestination::kActivationBuffer;
  int n64_tile_base_ = 0;
  std::deque<OutputRouterPacket> fifo_;
};

}  // namespace alexnet::golden

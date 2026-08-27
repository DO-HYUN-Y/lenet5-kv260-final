#include "alexnet_golden/output_router_ref.hpp"

#include <limits>
#include <stdexcept>
#include <utility>

namespace alexnet::golden {

N8OutputRouterRef::N8OutputRouterRef(int slice, std::size_t fifo_depth)
    : slice_(slice), fifo_depth_(fifo_depth) {
  if (slice < 0 || slice >= 8 || fifo_depth == 0) {
    throw std::invalid_argument("invalid N8 output-router geometry");
  }
}

void N8OutputRouterRef::reset() {
  fifo_.clear();
  configured_ = false;
  destination_ = OutputDestination::kActivationBuffer;
  n64_tile_base_ = 0;
}

void N8OutputRouterRef::configure(OutputDestination destination,
                                  int n64_tile_base) {
  if (!fifo_.empty()) {
    throw std::logic_error("cannot reconfigure a non-empty output router");
  }
  if (destination != OutputDestination::kActivationBuffer &&
      destination != OutputDestination::kPool3x3 &&
      destination != OutputDestination::kFinalOutput) {
    throw std::invalid_argument("invalid output-router destination");
  }
  if (n64_tile_base < 0 || n64_tile_base % 64 != 0 ||
      n64_tile_base > std::numeric_limits<int>::max() - 56) {
    throw std::invalid_argument("output-channel tile base must be N64 aligned");
  }
  destination_ = destination;
  n64_tile_base_ = n64_tile_base;
  configured_ = true;
}

OutputRouterPacket N8OutputRouterRef::make_packet(
    const OutputRouterIngress& ingress) const {
  if (!configured_) {
    throw std::logic_error("output router is not configured");
  }
  if (ingress.m < 0 || ingress.tile_tag < 0 || ingress.lane_mask == 0) {
    throw std::invalid_argument("invalid output-router ingress tag or mask");
  }
  for (int lane = 0; lane < 8; ++lane) {
    if ((ingress.lane_mask & (std::uint8_t{1} << lane)) == 0 &&
        ingress.values[static_cast<std::size_t>(lane)] != 0) {
      throw std::invalid_argument("masked output-router lanes must be zero");
    }
  }
  return OutputRouterPacket{
      destination_, slice_, ingress.m, n64_tile_base_ + slice_ * 8,
      ingress.tile_tag, ingress.lane_mask, ingress.values};
}

OutputRouterCycle N8OutputRouterRef::tick(
    bool ingress_valid, const OutputRouterIngress& ingress,
    bool egress_ready) {
  std::optional<OutputRouterPacket> egress;
  if (!fifo_.empty()) {
    egress = fifo_.front();
  }
  const bool pop = egress.has_value() && egress_ready;
  const bool ingress_ready =
      configured_ && (fifo_.size() < fifo_depth_ || pop);
  const bool push = ingress_valid && ingress_ready;

  std::optional<OutputRouterPacket> ingress_packet;
  if (push) {
    ingress_packet = make_packet(ingress);
  }
  if (pop) {
    fifo_.pop_front();
  }
  if (ingress_packet.has_value()) {
    fifo_.push_back(std::move(*ingress_packet));
  }
  return OutputRouterCycle{ingress_ready, std::move(egress)};
}

}  // namespace alexnet::golden

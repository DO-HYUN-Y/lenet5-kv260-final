#include <stdint.h>

uint32_t dma_golden_write_addr(int s2mm, int step) {
  static const uint32_t mm2s_offsets[4] = {0x00u, 0x04u, 0x18u, 0x28u};
  static const uint32_t s2mm_offsets[4] = {0x30u, 0x34u, 0x48u, 0x58u};
  if (step < 0 || step >= 4) {
    return UINT32_C(0xffffffff);
  }
  return UINT32_C(0xa0010000) +
         (s2mm ? s2mm_offsets[step] : mm2s_offsets[step]);
}

uint32_t dma_golden_write_data(int step, uint32_t buffer_addr,
                               uint32_t length_bytes) {
  switch (step) {
    case 0:
      return UINT32_C(0x00005001);
    case 1:
      return UINT32_C(0x00007000);
    case 2:
      return buffer_addr;
    case 3:
      return length_bytes;
    default:
      return UINT32_C(0xffffffff);
  }
}

uint32_t dma_golden_status_addr(int s2mm) {
  return UINT32_C(0xa0010000) + (s2mm ? UINT32_C(0x34)
                                           : UINT32_C(0x04));
}

uint32_t dma_golden_status(int poll_index, int complete_after,
                           int inject_error) {
  if (inject_error) {
    return UINT32_C(0x00004010);
  }
  if (poll_index >= complete_after) {
    return UINT32_C(0x00001002);
  }
  return UINT32_C(0x00000000);
}

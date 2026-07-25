#include <stdint.h>

int scheduler_golden_dma_count(int need_model) {
  return need_model ? 4 : 2;
}

int scheduler_golden_ingress_count(int need_model) {
  return need_model ? 3 : 1;
}

int scheduler_golden_dma_kind(int need_model, int index) {
  if (need_model) {
    static const int kinds[4] = {0, 1, 2, 3};
    return (index >= 0 && index < 4) ? kinds[index] : -1;
  }
  static const int kinds[2] = {2, 3};
  return (index >= 0 && index < 2) ? kinds[index] : -1;
}

uint32_t scheduler_golden_length(int kind) {
  switch (kind) {
    case 0:
      return UINT32_C(92736);
    case 1:
      return UINT32_C(1888);
    case 2:
      return UINT32_C(1024);
    case 3:
      return UINT32_C(10);
    default:
      return UINT32_C(0xffffffff);
  }
}

int scheduler_golden_ingress_mode(int need_model, int index) {
  if (need_model) {
    static const int modes[3] = {0, 1, 2};
    return (index >= 0 && index < 3) ? modes[index] : -1;
  }
  return (index == 0) ? 2 : -1;
}

uint32_t scheduler_golden_ingress_count_value(int mode) {
  switch (mode) {
    case 0:
      return UINT32_C(1449);
    case 1:
      return UINT32_C(236);
    case 2:
      return UINT32_C(512);
    default:
      return UINT32_C(0xffffffff);
  }
}

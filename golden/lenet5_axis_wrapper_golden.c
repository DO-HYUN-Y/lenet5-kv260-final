#include <stdint.h>

int wrapper_param_bias(int address) {
  if (address >= 226) {
    const int logit = address - 226 - 5;
    return 2 * logit;
  }
  return 2;
}

int wrapper_param_scale(int address) {
  (void)address;
  return 65536;
}

int wrapper_expected_logit(int index) {
  return index - 5;
}

int wrapper_expected_counter(int select) {
  switch (select) {
    case 0: return 10001;
    case 1: return 9184;
    case 2: return 250;
    case 3: return 520;
    default: return -1;
  }
}

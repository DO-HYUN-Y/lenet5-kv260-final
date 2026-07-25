#include <stdint.h>

uint32_t csr_apply_wstrb(uint32_t old_value, uint32_t new_value,
                         int strobe) {
  uint32_t value = old_value;
  for (int byte = 0; byte < 4; ++byte) {
    if ((strobe >> byte) & 1) {
      const uint32_t mask = UINT32_C(0xff) << (8 * byte);
      value = (value & ~mask) | (new_value & mask);
    }
  }
  return value;
}

uint32_t csr_expected_id(void) {
  return UINT32_C(0x00024c35);
}

uint32_t csr_expected_status(
    int core_busy, int core_done, int ingress_busy, int ingress_done,
    int result_busy, int result_done, int error, int model_valid,
    int input_valid, int result_set, int model_ready,
    int activation_ready, int op_index) {
  uint32_t value = 0;
  value |= (uint32_t)(core_busy & 1) << 0;
  value |= (uint32_t)(core_done & 1) << 1;
  value |= (uint32_t)(ingress_busy & 1) << 2;
  value |= (uint32_t)(ingress_done & 1) << 3;
  value |= (uint32_t)(result_busy & 1) << 4;
  value |= (uint32_t)(result_done & 1) << 5;
  value |= (uint32_t)(error & 1) << 6;
  value |= (uint32_t)(model_valid & 1) << 7;
  value |= (uint32_t)(input_valid & 1) << 8;
  value |= (uint32_t)(result_set & 1) << 9;
  value |= (uint32_t)(model_ready & 1) << 10;
  value |= (uint32_t)(activation_ready & 1) << 11;
  value |= (uint32_t)(op_index & 15) << 12;
  return value;
}

#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int alexnet_golden_packed_products(int8_t act_lo, int8_t act_hi, int8_t weight,
                                   int32_t* product_lo, int32_t* product_hi);

int alexnet_golden_requantize(int32_t accumulator, int32_t bias,
                              int32_t multiplier, uint8_t right_shift,
                              uint8_t relu, int8_t* output);

int alexnet_golden_linear_point(const int8_t* input, const int8_t* weights,
                                int k_depth, int32_t* accumulator);

int alexnet_golden_maxpool_point(const int8_t* input, int input_h, int input_w,
                                 int origin_y, int origin_x, int kernel_h,
                                 int kernel_w, int8_t* output);

#ifdef __cplusplus
}
#endif

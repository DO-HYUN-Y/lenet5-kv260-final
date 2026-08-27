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

int alexnet_golden_conv2d_accumulate(
    const int8_t* input, int batch, int input_channels, int input_h,
    int input_w, const int8_t* weights, int output_channels,
    int input_channels_per_group, int kernel_h, int kernel_w, int groups,
    int stride_h, int stride_w, int pad_h, int pad_w, int dilation_h,
    int dilation_w, int32_t* output, int output_count);

int alexnet_golden_conv2d_int8(
    const int8_t* input, int batch, int input_channels, int input_h,
    int input_w, const int8_t* weights, int output_channels,
    int input_channels_per_group, int kernel_h, int kernel_w, int groups,
    int stride_h, int stride_w, int pad_h, int pad_w, int dilation_h,
    int dilation_w, const int32_t* bias, const int32_t* multiplier,
    const uint8_t* right_shift, uint8_t relu, int8_t* output,
    int output_count);

int alexnet_golden_linear_accumulate(const int8_t* input, int m_count,
                                     int k_depth, const int8_t* weights,
                                     int n_count, int32_t* output,
                                     int output_count);

int alexnet_golden_linear_int8(
    const int8_t* input, int m_count, int k_depth, const int8_t* weights,
    int n_count, const int32_t* bias, const int32_t* multiplier,
    const uint8_t* right_shift, uint8_t relu, int8_t* output,
    int output_count);

int alexnet_golden_maxpool2d(const int8_t* input, int batch, int channels,
                             int input_h, int input_w, int kernel_h,
                             int kernel_w, int stride_h, int stride_w,
                             int pad_h, int pad_w, int8_t* output,
                             int output_count);

int alexnet_golden_packed_os_matmul(const int8_t* activations, int m_count,
                                    int k_depth, const int8_t* weights,
                                    int n_count, int32_t* output,
                                    int output_count);

#ifdef __cplusplus
}
#endif

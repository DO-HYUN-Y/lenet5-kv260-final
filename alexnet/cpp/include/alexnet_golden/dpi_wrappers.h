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

int alexnet_golden_maxpool3x3_n8(
    uint64_t p00, uint64_t p01, uint64_t p02,
    uint64_t p10, uint64_t p11, uint64_t p12,
    uint64_t p20, uint64_t p21, uint64_t p22,
    uint8_t lane_mask, uint64_t* output);

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

int alexnet_golden_scanner_reset(int m_count, int n_count, int n_base);
int alexnet_golden_scanner_tick(uint8_t ready, uint8_t* valid, int32_t* m,
                                uint8_t* n_lane_mask);

int alexnet_golden_router_reset(int slice, int fifo_depth);
int alexnet_golden_router_configure(uint8_t destination,
                                    int32_t n64_tile_base);
int alexnet_golden_router_tick(
    uint8_t ingress_valid, int32_t ingress_m, int32_t ingress_tile_tag,
    uint8_t ingress_lane_mask, uint64_t ingress_values,
    uint8_t egress_ready, uint8_t* ingress_ready, uint8_t* egress_valid,
    uint8_t* egress_destination, int32_t* egress_slice, int32_t* egress_m,
    int32_t* egress_n_base, int32_t* egress_tile_tag,
    uint8_t* egress_lane_mask, uint64_t* egress_values);
int alexnet_golden_router_queued(int32_t* queued_packets);

int alexnet_golden_activation_bank_reset(int depth);
int alexnet_golden_activation_bank_begin_fill(int word_count,
                                              uint8_t lane_mask,
                                              int tensor_tag);
int alexnet_golden_activation_bank_write(uint64_t values, uint8_t lane_mask,
                                         uint8_t last);
int alexnet_golden_activation_bank_begin_read(void);
int alexnet_golden_activation_bank_word(int index, uint64_t* values,
                                        uint8_t* lane_mask, uint8_t* last,
                                        int* tensor_tag);
int alexnet_golden_activation_bank_complete_read(void);
int alexnet_golden_activation_bank_state(uint8_t* state, int* words_written);

int alexnet_golden_activation_pingpong_reset(int depth);
int alexnet_golden_activation_pingpong_begin_fill(
    uint8_t is_pooled, int word_count, uint8_t lane_mask, int tensor_tag,
    uint8_t* bank);
int alexnet_golden_activation_pingpong_write(
    uint8_t is_pooled, uint64_t values, uint8_t lane_mask, uint8_t last);
int alexnet_golden_activation_pingpong_begin_read(int tensor_tag,
                                                   uint8_t* bank);
int alexnet_golden_activation_pingpong_word(
    int index, uint64_t* values, uint8_t* lane_mask, uint8_t* last,
    int* tensor_tag);
int alexnet_golden_activation_pingpong_complete_read(void);
int alexnet_golden_activation_pingpong_state(
    uint8_t* bank0_state, int* bank0_words, uint8_t* bank1_state,
    int* bank1_words, int* ready_count, uint8_t* ready_valid,
    uint8_t* ready_bank, int* ready_tag, uint8_t* fill_active,
    uint8_t* fill_bank, uint8_t* fill_is_pooled, uint8_t* read_active,
    uint8_t* read_bank);

int alexnet_golden_activation_dual_segment_pingpong_reset(int segment_depth);
int alexnet_golden_activation_dual_segment_pingpong_begin_fill(
    uint8_t is_pooled, int word_count, uint8_t lane_mask, int tensor_tag,
    uint8_t* bank);
int alexnet_golden_activation_dual_segment_pingpong_write(
    uint8_t is_pooled, uint64_t values, uint8_t lane_mask, uint8_t last);
int alexnet_golden_activation_dual_segment_pingpong_begin_read(
    int tensor_tag, uint8_t* bank);
int alexnet_golden_activation_dual_segment_pingpong_word(
    int global_index, uint64_t* values, uint8_t* lane_mask, uint8_t* last,
    int* tensor_tag);
int alexnet_golden_activation_dual_segment_pingpong_complete_segment0(void);
int alexnet_golden_activation_dual_segment_pingpong_complete_read(void);
int alexnet_golden_activation_dual_segment_pingpong_state(
    int* ready_count, uint8_t* ready_valid, uint8_t* ready_bank,
    int* ready_tag, uint8_t* fill_active, uint8_t* fill_bank,
    uint8_t* fill_is_pooled, uint8_t* read_active, uint8_t* read_bank,
    uint8_t* read_segment);

int alexnet_golden_weight_tile_bank_reset(int depth);
int alexnet_golden_weight_tile_bank_begin_fill(int k_count,
                                                uint8_t n_lane_mask,
                                                int context_tag);
int alexnet_golden_weight_tile_bank_write(uint64_t values,
                                           uint8_t n_lane_mask,
                                           uint8_t last);
int alexnet_golden_weight_tile_bank_begin_replay(int k_count,
                                                  uint8_t n_lane_mask,
                                                  int context_tag);
int alexnet_golden_weight_tile_bank_word(int k, uint64_t* values,
                                          uint8_t* n_lane_mask,
                                          uint8_t* last,
                                          int* context_tag);
int alexnet_golden_weight_tile_bank_complete_replay(void);
int alexnet_golden_weight_tile_bank_release(void);
int alexnet_golden_weight_tile_bank_state(uint8_t* state,
                                           int* words_written,
                                           int* completed_replays);

int alexnet_golden_partial_sum_bank_reset(int depth);
int alexnet_golden_partial_sum_bank_begin_chunk(
    int word_count, uint8_t n_lane_mask, int context_tag, int chunk_index,
    uint8_t first_chunk, uint8_t final_chunk);
int alexnet_golden_partial_sum_bank_write(
    int index, int32_t accumulator0, int32_t accumulator1,
    int32_t accumulator2, int32_t accumulator3, int32_t accumulator4,
    int32_t accumulator5, int32_t accumulator6, int32_t accumulator7,
    uint8_t n_lane_mask, uint8_t last);
int alexnet_golden_partial_sum_bank_word(
    int index, int32_t* accumulator0, int32_t* accumulator1,
    int32_t* accumulator2, int32_t* accumulator3, int32_t* accumulator4,
    int32_t* accumulator5, int32_t* accumulator6, int32_t* accumulator7,
    uint8_t* n_lane_mask, uint8_t* last, int* context_tag);
int alexnet_golden_partial_sum_bank_complete_emit(void);
int alexnet_golden_partial_sum_bank_state(uint8_t* state,
                                           int* words_accepted,
                                           int* next_chunk_index,
                                           int* completed_chunks);

int alexnet_golden_window_m4_reset(int input_h, int input_w,
                                   int channel_count, int kernel,
                                   int stride, int padding);
int alexnet_golden_window_m4_set_pixel(int y, int x, uint64_t values);
int alexnet_golden_window_m4_token(int output_y, int output_x_base,
                                   int m_count, int k_index,
                                   uint32_t* activations,
                                   uint8_t* m_lane_mask,
                                   uint8_t* tile_clear,
                                   uint8_t* reduce_last);

#ifdef __cplusplus
}
#endif

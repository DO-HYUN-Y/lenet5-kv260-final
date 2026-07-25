/* conv_stream_golden.c -- algorithmic reference for the integrated stream.
 * The image deliberately contains five consecutive all-zero rows, exercising
 * the one-token all-zero flush and every partial row-zero compaction case. */
#include <stdint.h>

#define C_IN 2
#define W 13
#define H 13
#define K 5
#define OUT_W 9
#define OUT_H 9

static int pixel_at(int y, int ch, int x) {
    if (y < 0 || y >= H || ch < 0 || ch >= C_IN || x < 0 || x >= W) return 0;
    if (y >= 3 && y <= 7) return 0;
    return ((y + 3) * 19 + (ch + 5) * 11 + (x + 7) * 3) % 31 - 15;
}

int golden_pixel(int index) {
    int row_width = C_IN * W;
    int y = index / row_width;
    int in_row = index % row_width;
    int ch = in_row / W;
    int x = in_row % W;
    return pixel_at(y, ch, x);
}

int golden_weight(int k, int col) {
    return ((k + 3) * 13 + (col + 1) * 7) % 23 - 11;
}

int golden_win(int out_y, int tile_x, int k, int lane) {
    int kr = k / (K * C_IN);
    int rem = k % (K * C_IN);
    int kc = rem / C_IN;
    int ch = rem % C_IN;
    return pixel_at(out_y + kr, ch, tile_x * 8 + kc + lane);
}

int golden_sum(int out_y, int out_x, int col) {
    int sum = 0;
    for (int kr = 0; kr < K; ++kr)
        for (int kc = 0; kc < K; ++kc)
            for (int ch = 0; ch < C_IN; ++ch) {
                int k = (kr * K + kc) * C_IN + ch;
                sum += pixel_at(out_y + kr, ch, out_x + kc) * golden_weight(k, col);
            }
    return sum;
}

int golden_output_addr(int base, int channel, int out_y, int out_x) {
    return base + channel * (OUT_W * OUT_H) + out_y * OUT_W + out_x;
}

int golden_bias(int group, int col, int lane) {
    return ((group + 1) * 17 + (col + 2) * 5 + lane * 3) % 21 - 10;
}

int golden_scale(int group, int col, int lane) {
    return 40000 + ((group * 8 + col) * 2 + lane) * 311;
}

static int requantize(int acc, int bias, int scale, int relu_en) {
    const int64_t max_input = ((int64_t)1 << 26) - 1;
    const int64_t min_input = -((int64_t)1 << 26);
    int64_t value = (int64_t)acc + bias;
    int64_t product;
    uint64_t magnitude;
    int64_t shifted;

    if (relu_en && value < 0) value = 0;
    if (value > max_input) value = max_input;
    if (value < min_input) value = min_input;
    product = value * scale;
    magnitude = (product < 0) ? (uint64_t)(-product) : (uint64_t)product;
    magnitude = (magnitude + ((uint64_t)1 << 16)) >> 17;
    shifted = (product < 0) ? -(int64_t)magnitude : (int64_t)magnitude;
    if (shifted > 127) return 127;
    if (shifted < -128) return -128;
    return (int)shifted;
}

int golden_postprocessed(int out_y, int out_x, int col,
                         int group, int lane) {
    return requantize(golden_sum(out_y, out_x, col),
                      golden_bias(group, col, lane),
                      golden_scale(group, col, lane), 1);
}

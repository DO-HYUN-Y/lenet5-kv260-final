/* fc_stream_golden.c -- full FC dot-product and requant reference. */
#include <stdint.h>

#define FC_DEPTH 23

int fc_golden_activation(int k) {
    return ((k + 7) * 29) % 31 - 15;
}

int fc_golden_weight(int filter, int k) {
    return ((filter + 3) * 11 + (k + 5) * 17) % 23 - 11;
}

int fc_golden_sum(int filter) {
    int sum = 0;
    for (int k = 0; k < FC_DEPTH; ++k)
        sum += fc_golden_activation(k) * fc_golden_weight(filter, k);
    return sum;
}

int fc_golden_bias(int filter) {
    return ((filter + 2) * 13) % 41 - 20;
}

int fc_golden_scale(int filter) {
    return 36000 + (filter * 277) % 50000;
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

int fc_golden_postprocessed(int filter, int relu_en) {
    return requantize(fc_golden_sum(filter), fc_golden_bias(filter),
                      fc_golden_scale(filter), relu_en);
}

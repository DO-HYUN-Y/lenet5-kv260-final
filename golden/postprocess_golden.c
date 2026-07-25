/* postprocess_golden.c -- pure scalar reference for dual-lane requantization. */
#include <stdint.h>

#define MUL_IN_W 27
#define SCALE_SHIFT 17

int postprocess_golden(int acc, int bias, int scale, int relu_en) {
    const int64_t max_input = ((int64_t)1 << (MUL_IN_W - 1)) - 1;
    const int64_t min_input = -((int64_t)1 << (MUL_IN_W - 1));
    int64_t value = (int64_t)acc + (int64_t)bias;
    int64_t product;
    uint64_t magnitude;
    int64_t shifted;

    if (relu_en && value < 0) value = 0;
    if (value > max_input) value = max_input;
    if (value < min_input) value = min_input;

    product = value * (int64_t)scale;
    magnitude = (product < 0) ? (uint64_t)(-product) : (uint64_t)product;
    magnitude = (magnitude + ((uint64_t)1 << (SCALE_SHIFT - 1))) >>
                SCALE_SHIFT;
    shifted = (product < 0) ? -(int64_t)magnitude : (int64_t)magnitude;

    if (shifted > 127) return 127;
    if (shifted < -128) return -128;
    return (int)shifted;
}

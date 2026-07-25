/* maxpool2x2_golden.c -- scalar signed-INT8 2x2 MaxPool reference. */
#include <stdint.h>

int maxpool2x2_golden(int top_pair, int bottom_pair) {
    const int8_t top_lo = (int8_t)(top_pair & 0xff);
    const int8_t top_hi = (int8_t)((top_pair >> 8) & 0xff);
    const int8_t bottom_lo = (int8_t)(bottom_pair & 0xff);
    const int8_t bottom_hi = (int8_t)((bottom_pair >> 8) & 0xff);
    int8_t result = top_lo;

    if (top_hi > result) result = top_hi;
    if (bottom_lo > result) result = bottom_lo;
    if (bottom_hi > result) result = bottom_hi;
    return (int)result;
}

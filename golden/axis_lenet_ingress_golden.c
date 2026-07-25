#include <stdint.h>

int ingress_weight_byte(int seed, int transaction, int byte_index) {
    uint32_t x = (uint32_t)seed;
    x ^= (uint32_t)(transaction + 1) * 0x45d9f3bu;
    x += (uint32_t)(byte_index + 3) * 0x27d4eb2du;
    x ^= x >> 15;
    return (int)(x & 0xffu);
}

int ingress_param_bias(int seed, int transaction, int index) {
    int value = (seed + transaction * 97 + index * 37) % 2001;
    return value - 1000;
}

int ingress_param_scale(int seed, int transaction, int index) {
    int value = (seed * 3 + transaction * 53 + index * 101) % 262143;
    return value - 131071;
}

int ingress_activation_word(int seed, int transaction, int index) {
    uint32_t lo = (uint32_t)(
        seed + transaction * 19 + index * 11
    ) & 0xffu;
    uint32_t hi = (uint32_t)(
        seed * 5 + transaction * 23 + index * 29
    ) & 0xffu;
    return (int)((hi << 8) | lo);
}

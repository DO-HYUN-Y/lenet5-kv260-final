#include <stdint.h>

int result_expected_bank(int bank_base, int index, int banks) {
    return (bank_base + index) % banks;
}

int result_expected_addr(int base, int bank_base, int index, int banks) {
    return base + (bank_base + index) / banks;
}

int result_expected_word(int seed, int transaction, int index) {
    uint32_t lo = (uint32_t)(
        seed + transaction * 43 + index * 17
    ) & 0xffu;
    uint32_t hi = (uint32_t)(
        seed * 7 + transaction * 13 + index * 31
    ) & 0xffu;
    return (int)((hi << 8) | lo);
}

int result_expected_keep(int word_count) {
    int bytes = word_count * 2;
    if (bytes >= 16)
        return 0xffff;
    return (1 << bytes) - 1;
}

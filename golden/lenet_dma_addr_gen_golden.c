#include <stdint.h>

enum {
    MODE_WEIGHT = 0,
    MODE_PARAM = 1,
    MODE_INPUT = 2,
    MODE_RESULT = 3
};

int agen_expected_weight_addr(int mode, int base, int index) {
    return mode == MODE_WEIGHT ? base + index : 0;
}

int agen_expected_param_addr(int mode, int base, int index) {
    return mode == MODE_PARAM ? base + index : 0;
}

int agen_expected_bank(int mode, int bank_base, int index, int banks) {
    if (mode == MODE_INPUT)
        return bank_base;
    if (mode == MODE_RESULT)
        return (bank_base + index) % banks;
    return 0;
}

int agen_expected_bank_addr(
    int mode, int base, int bank_base, int index, int banks
) {
    if (mode == MODE_INPUT)
        return base + index;
    if (mode == MODE_RESULT)
        return base + (bank_base + index) / banks;
    return 0;
}
